#requires -Version 5.1
<#
    PSHPatcher v2 - Windows Update CU Remote Installer
    Interface grafica (WinForms) para checagem e instalacao remota de
    Cumulative Updates (.msu / .cab) em multiplos hosts, em paralelo.

    Recursos:
      - Selecao do arquivo de update (.msu/.cab) com deteccao de KB/arquitetura/SO
      - Preflight check por host: ping, WinRM, build atual, disco livre,
        reboot pendente, KB ja instalado
      - Instalacao em paralelo (runspaces) com limite configuravel de threads
      - Status em tempo real por estagio (Verificando / Copiando / Instalando / Concluido / Erro)
      - Exportacao de relatorio em CSV
      - Suporte a credencial alternativa para o Invoke-Command / PSSession

    Uso:
      powershell.exe -ExecutionPolicy Bypass -File .\PSHPatcher-v2.ps1
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------------------
# Estado global
# ---------------------------------------------------------------------------
$script:UpdateFilePath = $null
$script:UpdateInfo      = $null
$script:Credential      = $null
$script:RunspacePool    = $null
$script:Jobs            = New-Object System.Collections.Generic.List[object]
$script:SyncHash        = [hashtable]::Synchronized(@{})
$script:RowIndexByHost  = @{}

# ---------------------------------------------------------------------------
# Helpers puros (rodam na thread principal)
# ---------------------------------------------------------------------------

function Get-UpdateFileInfo {
    param([Parameter(Mandatory)][string]$Path)

    $name = Split-Path $Path -Leaf
    $kb = $null
    if ($name -match '(?i)kb(\d{6,7})') { $kb = "KB$($matches[1])" }

    $arch = 'Desconhecida'
    if ($name -match '(?i)x64')        { $arch = 'x64' }
    elseif ($name -match '(?i)arm64')  { $arch = 'ARM64' }
    elseif ($name -match '(?i)x86')    { $arch = 'x86' }

    $osHint = 'Desconhecido'
    if ($name -match '(?i)windows11\.0')      { $osHint = 'Windows 11' }
    elseif ($name -match '(?i)windows10\.0')  { $osHint = 'Windows 10' }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()

    [PSCustomObject]@{
        Path       = $Path
        FileName   = $name
        Extension  = $ext
        KB         = $kb
        Arch       = $arch
        OSHint     = $osHint
        SizeMB     = [math]::Round((Get-Item $Path).Length / 1MB, 1)
    }
}

function Test-Compatibility {
    param($UpdateInfo, [string]$RemoteOSCaption, [string]$RemoteArch)

    if (-not $UpdateInfo) { return $false }
    $osOk = $true
    if ($UpdateInfo.OSHint -ne 'Desconhecido' -and $RemoteOSCaption) {
        $osOk = $RemoteOSCaption -match [regex]::Escape($UpdateInfo.OSHint)
    }
    $archOk = $true
    if ($UpdateInfo.Arch -ne 'Desconhecida' -and $RemoteArch) {
        if ($UpdateInfo.Arch -eq 'x64')   { $archOk = $RemoteArch -match '64' }
        elseif ($UpdateInfo.Arch -eq 'x86') { $archOk = $RemoteArch -match '32' }
        elseif ($UpdateInfo.Arch -eq 'ARM64') { $archOk = $RemoteArch -match 'ARM' }
    }
    return ($osOk -and $archOk)
}

# Mapeamento de exit codes comuns do wusa.exe / DISM
function Get-FriendlyExitDetail {
    param([int]$ExitCode)
    switch ($ExitCode) {
        0        { return 'Instalado com sucesso' }
        3010     { return 'Instalado - reinicio necessario' }
        2359302  { return 'Update ja instalado (WU_S_ALREADY_INSTALLED)' }
        87       { return 'Parametro invalido para o instalador' }
        123      { return 'Erro 123 (ERROR_INVALID_NAME) - sintaxe do caminho do pacote invalida no host' }
        1642     { return 'Pacote nao aplicavel a este SO' }
        1603     { return 'Erro fatal na instalacao' }
        1618     { return 'Outra instalacao em andamento no host' }
        -1       { return 'Falha de comunicacao/timeout' }
        -2       { return 'Pacote nao encontrado no host apos a copia (falha silenciosa no Copy-Item)' }
        default  { return "Exit code $ExitCode" }
    }
}

# ---------------------------------------------------------------------------
# Scriptblock executado DENTRO do host remoto (via Invoke-Command)
# Coleta build atual, disco livre, reboot pendente e se o KB ja esta instalado
# ---------------------------------------------------------------------------
$script:RemoteInventoryBlock = {
    param($TargetKB)
    $os   = Get-CimInstance Win32_OperatingSystem
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"

    $rebootPending = $false
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $regPaths) { if (Test-Path $p) { $rebootPending = $true } }

    $hasKB = $false
    if ($TargetKB) {
        $hasKB = [bool](Get-HotFix -Id $TargetKB -ErrorAction SilentlyContinue)
    }

    [PSCustomObject]@{
        ComputerName  = $env:COMPUTERNAME
        OSCaption     = $os.Caption
        OSArch        = $os.OSArchitecture
        BuildNumber   = $os.BuildNumber
        Version       = $os.Version
        FreeDiskGB    = [math]::Round($disk.FreeSpace / 1GB, 1)
        RebootPending = $rebootPending
        HasKB         = $hasKB
    }
}

# ---------------------------------------------------------------------------
# Worker de PREFLIGHT (roda em runspace paralelo por host)
# Escreve estagios em $SyncHash para a UI ler em tempo real
# ---------------------------------------------------------------------------
$script:PreflightWorker = {
    param($HostName, $Credential, $KB, $InventoryBlock, $SyncHash)

    function Set-Stage($status, $detail) {
        $SyncHash[$HostName] = @{
            Status = $status; Detail = $detail; Stage = $status
        }
    }

    Set-Stage 'Verificando' 'Testando conectividade (ping)...'
    $online = Test-Connection -ComputerName $HostName -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $online) {
        Set-Stage 'Erro' 'Host offline (sem resposta de ping)'
        return [PSCustomObject]@{ HostName=$HostName; Online=$false; WinRM=$false; Status='Erro'; Detail='Host offline'; RebootPending=$null; FreeDiskGB=$null; OSCaption=$null; BuildNumber=$null; HasKB=$null }
    }

    Set-Stage 'Verificando' 'Testando WinRM...'
    $wsmanOk = $false
    $hasCred = ($Credential -is [System.Management.Automation.PSCredential])
    try {
        $params = @{ ComputerName = $HostName; ErrorAction = 'Stop' }
        if ($hasCred) { $params.Credential = $Credential }
        Test-WSMan @params | Out-Null
        $wsmanOk = $true
    } catch { $wsmanOk = $false }

    if (-not $wsmanOk) {
        Set-Stage 'Erro' 'WinRM indisponivel neste host'
        return [PSCustomObject]@{ HostName=$HostName; Online=$true; WinRM=$false; Status='Erro'; Detail='WinRM indisponivel'; RebootPending=$null; FreeDiskGB=$null; OSCaption=$null; BuildNumber=$null; HasKB=$null }
    }

    Set-Stage 'Verificando' 'Coletando inventario (build, disco, reboot pendente)...'
    try {
        $icParams = @{ ComputerName = $HostName; ScriptBlock = $InventoryBlock; ArgumentList = @($KB); ErrorAction = 'Stop' }
        if ($hasCred) { $icParams.Credential = $Credential }
        $inv = Invoke-Command @icParams
    } catch {
        Set-Stage 'Erro' "Falha ao coletar inventario: $($_.Exception.Message)"
        return [PSCustomObject]@{ HostName=$HostName; Online=$true; WinRM=$true; Status='Erro'; Detail=$_.Exception.Message; RebootPending=$null; FreeDiskGB=$null; OSCaption=$null; BuildNumber=$null; HasKB=$null }
    }

    Set-Stage 'Verificado' 'Inventario coletado'
    [PSCustomObject]@{
        HostName      = $HostName
        Online        = $true
        WinRM         = $true
        Status        = 'Verificado'
        Detail        = 'Pronto para instalacao'
        RebootPending = $inv.RebootPending
        FreeDiskGB    = $inv.FreeDiskGB
        OSCaption     = $inv.OSCaption
        OSArch        = $inv.OSArch
        BuildNumber   = $inv.BuildNumber
        HasKB         = $inv.HasKB
    }
}

# ---------------------------------------------------------------------------
# Worker de INSTALACAO (copia o pacote e executa wusa/DISM remotamente)
#
# v2.1 FIX:
#   1. Valida o arquivo local antes de iniciar.
#   2. Cria C:\Temp\PSHPatcher pelo proprio PSSession.
#   3. Tenta SMB primeiro para desempenho.
#   4. Quando ha credencial alternativa, usa de fato o PSDrive mapeado
#      (o codigo anterior criava o drive, mas continuava copiando pelo UNC bruto).
#   5. Se SMB/C$ falhar, faz fallback automatico para Copy-Item -ToSession.
#   6. Confirma no host remoto que tamanho do arquivo copiado = tamanho da origem.
# ---------------------------------------------------------------------------
$script:InstallWorker = {
    param($HostName, $Credential, $LocalFilePath, $FileName, $Extension, $SyncHash)

    function Set-Stage($status, $detail) {
        $SyncHash[$HostName] = @{
            Status = $status
            Detail = $detail
            Stage  = $status
        }
    }

    $session = $null
    $psdrive = $null
    $copyMethod = $null

    try {
        # O erro exibido na v2 vinha daqui em varios cenarios:
        # o runspace chegava ao Copy-Item com uma origem que nao podia ser resolvida.
        Set-Stage 'Validando' 'Validando arquivo de update na maquina de origem...'

        if ([string]::IsNullOrWhiteSpace($LocalFilePath)) {
            throw 'O caminho local do pacote esta vazio.'
        }

        if (-not (Test-Path -LiteralPath $LocalFilePath -PathType Leaf)) {
            throw "Arquivo de update nao encontrado na maquina de origem: $LocalFilePath"
        }

        $localItem = Get-Item -LiteralPath $LocalFilePath -ErrorAction Stop
        $localLength = [int64]$localItem.Length

        Set-Stage 'Conectando' 'Abrindo sessao remota (PSSession)...'

        $hasCred = ($Credential -is [System.Management.Automation.PSCredential])
        $sParams = @{
            ComputerName = $HostName
            ErrorAction  = 'Stop'
        }
        if ($hasCred) {
            $sParams.Credential = $Credential
        }

        $session = New-PSSession @sParams

        $remoteDir  = 'C:\Temp\PSHPatcher'
        $remotePath = Join-Path $remoteDir $FileName

        # A pasta remota e criada pelo WinRM. Isso evita depender de C$ apenas
        # para criar a estrutura.
        Set-Stage 'Preparando' 'Criando pasta temporaria no host...'
        Invoke-Command -Session $session -ScriptBlock {
            param($dir)
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
        } -ArgumentList $remoteDir -ErrorAction Stop

        # -------------------------------------------------------------------
        # Copia principal: SMB/C$ (mais rapido para CU de 1 GB+)
        # -------------------------------------------------------------------
        $smbCopied = $false
        try {
            Set-Stage 'Copiando' "Copiando $FileName via SMB (C`$)..."

            if ($hasCred) {
                # IMPORTANTE: se uma credencial alternativa foi fornecida,
                # usamos o caminho DO PSDrive. O codigo anterior mapeava um drive
                # e depois ignorava o drive, copiando pelo UNC bruto.
                $safeHost = ($HostName -replace '[^a-zA-Z0-9]', '')
                if ([string]::IsNullOrWhiteSpace($safeHost)) { $safeHost = 'HOST' }
                if ($safeHost.Length -gt 8) { $safeHost = $safeHost.Substring(0, 8) }

                $driveName = "P$($safeHost)$([Guid]::NewGuid().ToString('N').Substring(0,4))"
                $psdrive = New-PSDrive `
                    -Name $driveName `
                    -PSProvider FileSystem `
                    -Root "\\$HostName\C`$" `
                    -Credential $Credential `
                    -Scope Local `
                    -ErrorAction Stop

                $destDir  = "$($psdrive.Name):\Temp\PSHPatcher"
                $destFile = Join-Path $destDir $FileName

                if (-not (Test-Path -LiteralPath $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                Copy-Item `
                    -LiteralPath $LocalFilePath `
                    -Destination $destFile `
                    -Force `
                    -ErrorAction Stop
            }
            else {
                $uncDir  = "\\$HostName\C`$\Temp\PSHPatcher"
                $uncFile = Join-Path $uncDir $FileName

                if (-not (Test-Path -LiteralPath $uncDir)) {
                    New-Item -Path $uncDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                Copy-Item `
                    -LiteralPath $LocalFilePath `
                    -Destination $uncFile `
                    -Force `
                    -ErrorAction Stop
            }

            $smbCopied = $true
            $copyMethod = 'SMB'
        }
        catch {
            # C$ pode estar bloqueado, UAC remoto pode limitar admin share,
            # ou ja pode existir uma conexao SMB com outra credencial.
            # Nesses casos, WinRM ja esta aberto: fazemos fallback automatico.
            $smbError = $_.Exception.Message
            Set-Stage 'Copiando' "SMB indisponivel. Tentando copia pelo WinRM..."
        }

        # -------------------------------------------------------------------
        # Fallback: copia pela PSSession
        # -------------------------------------------------------------------
        if (-not $smbCopied) {
            try {
                Copy-Item `
                    -LiteralPath $LocalFilePath `
                    -Destination $remotePath `
                    -ToSession $session `
                    -Force `
                    -ErrorAction Stop

                $copyMethod = 'WinRM'
            }
            catch {
                $winrmCopyError = $_.Exception.Message
                throw "Falha ao copiar o pacote. SMB: $smbError | WinRM: $winrmCopyError"
            }
        }

        # Confirma existencia e tamanho antes de executar qualquer instalador.
        Set-Stage 'Validando copia' 'Confirmando integridade basica do arquivo copiado...'

        $remoteFileInfo = Invoke-Command -Session $session -ScriptBlock {
            param($path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return $null
            }
            $item = Get-Item -LiteralPath $path -ErrorAction Stop
            [PSCustomObject]@{
                Exists = $true
                Length = [int64]$item.Length
            }
        } -ArgumentList $remotePath -ErrorAction Stop

        if (-not $remoteFileInfo -or -not $remoteFileInfo.Exists) {
            throw "O pacote nao foi encontrado no host apos a copia: $remotePath"
        }

        if ([int64]$remoteFileInfo.Length -ne $localLength) {
            throw "Copia incompleta: origem=$localLength bytes; destino=$($remoteFileInfo.Length) bytes."
        }

        # -------------------------------------------------------------------
        # Instalacao
        # -------------------------------------------------------------------
        Set-Stage 'Instalando' "Executando instalador no host (copia: $copyMethod)..."

        $exitCode = Invoke-Command -Session $session -ScriptBlock {
            param($pkgPath, $ext)

            if (-not (Test-Path -LiteralPath $pkgPath -PathType Leaf)) {
                return -2
            }

            if ($ext -eq '.msu') {
                # Caminho remoto nao contem espacos por padrao, mas a construcao
                # continua segura usando ArgumentList separado.
                $p = Start-Process `
                    -FilePath "$env:SystemRoot\System32\wusa.exe" `
                    -ArgumentList @($pkgPath, '/quiet', '/norestart') `
                    -Wait `
                    -PassThru `
                    -ErrorAction Stop
            }
            elseif ($ext -eq '.cab') {
                $p = Start-Process `
                    -FilePath "$env:SystemRoot\System32\dism.exe" `
                    -ArgumentList @('/Online', '/Add-Package', "/PackagePath:$pkgPath", '/NoRestart', '/Quiet') `
                    -Wait `
                    -PassThru `
                    -ErrorAction Stop
            }
            else {
                throw "Extensao de pacote nao suportada: $ext"
            }

            return [int]$p.ExitCode
        } -ArgumentList $remotePath, $Extension -ErrorAction Stop

        Set-Stage 'Limpando' 'Removendo pacote temporario do host...'
        Invoke-Command -Session $session -ScriptBlock {
            param($p)
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        } -ArgumentList $remotePath -ErrorAction SilentlyContinue

        $rebootNeeded = ($exitCode -eq 3010)
        $success = (
            $exitCode -eq 0 -or
            $exitCode -eq 3010 -or
            $exitCode -eq 2359302
        )

        $finalStatus = if ($success) { 'Sucesso' } else { 'Erro' }
        Set-Stage $finalStatus "Instalacao finalizada. Exit code: $exitCode"

        [PSCustomObject]@{
            HostName      = $HostName
            ExitCode      = $exitCode
            Success       = $success
            RebootPending = $rebootNeeded
            RemotePath    = $remotePath
            CopyMethod    = $copyMethod
            Status        = $finalStatus
            Detail        = $null
        }
    }
    catch {
        $msg = $_.Exception.Message
        Set-Stage 'Erro' $msg

        [PSCustomObject]@{
            HostName      = $HostName
            ExitCode      = -1
            Success       = $false
            RebootPending = $null
            RemotePath    = $null
            CopyMethod    = $copyMethod
            Status        = 'Erro'
            Detail        = $msg
        }
    }
    finally {
        if ($psdrive) {
            Remove-PSDrive -Name $psdrive.Name -Force -ErrorAction SilentlyContinue
        }
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

# ===========================================================================
# INTERFACE GRAFICA
# ===========================================================================

$form                  = New-Object System.Windows.Forms.Form
$form.Text             = 'PSHPatcher v2.2 - Windows CU Remote Installer'
$form.Size             = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition    = 'CenterScreen'
$form.MinimumSize      = New-Object System.Drawing.Size(900, 550)

# --- Painel esquerdo: lista de hosts ---------------------------------------
$lblHosts = New-Object System.Windows.Forms.Label
$lblHosts.Text = 'Hosts - 1 por linha'
$lblHosts.Location = New-Object System.Drawing.Point(12, 12)
$lblHosts.AutoSize = $true
$form.Controls.Add($lblHosts)

$txtHosts = New-Object System.Windows.Forms.TextBox
$txtHosts.Multiline = $true
$txtHosts.ScrollBars = 'Vertical'
$txtHosts.Location = New-Object System.Drawing.Point(12, 34)
$txtHosts.Size = New-Object System.Drawing.Size(220, 560)
$txtHosts.Anchor = 'Top,Bottom,Left'
$form.Controls.Add($txtHosts)

$btnLoadHosts = New-Object System.Windows.Forms.Button
$btnLoadHosts.Text = 'Load hosts.txt'
$btnLoadHosts.Location = New-Object System.Drawing.Point(12, 602)
$btnLoadHosts.Size = New-Object System.Drawing.Size(105, 30)
$btnLoadHosts.Anchor = 'Bottom,Left'
$form.Controls.Add($btnLoadHosts)

$btnCredential = New-Object System.Windows.Forms.Button
$btnCredential.Text = 'Definir credencial'
$btnCredential.Location = New-Object System.Drawing.Point(127, 602)
$btnCredential.Size = New-Object System.Drawing.Size(105, 30)
$btnCredential.Anchor = 'Bottom,Left'
$form.Controls.Add($btnCredential)

$lblCredStatus = New-Object System.Windows.Forms.Label
$lblCredStatus.Text = 'Credencial: contexto atual'
$lblCredStatus.Location = New-Object System.Drawing.Point(12, 638)
$lblCredStatus.AutoSize = $true
$lblCredStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblCredStatus.Anchor = 'Bottom,Left'
$form.Controls.Add($lblCredStatus)

# --- Painel superior direito: selecao de update + acoes --------------------
$grpFile = New-Object System.Windows.Forms.GroupBox
$grpFile.Text = 'Pacote de update'
$grpFile.Location = New-Object System.Drawing.Point(244, 8)
$grpFile.Size = New-Object System.Drawing.Size(914, 58)
$grpFile.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpFile)

$btnSelectFile = New-Object System.Windows.Forms.Button
$btnSelectFile.Text = 'Selecionar arquivo (.msu/.cab)...'
$btnSelectFile.Location = New-Object System.Drawing.Point(10, 20)
$btnSelectFile.Size = New-Object System.Drawing.Size(200, 28)
$grpFile.Controls.Add($btnSelectFile)

$lblFileInfo = New-Object System.Windows.Forms.Label
$lblFileInfo.Text = 'Nenhum arquivo selecionado.'
$lblFileInfo.Location = New-Object System.Drawing.Point(220, 25)
$lblFileInfo.AutoSize = $true
$lblFileInfo.Anchor = 'Top,Left,Right'
$grpFile.Controls.Add($lblFileInfo)

# --- Toolbar de acoes --------------------------------------------------------
$grpActions = New-Object System.Windows.Forms.GroupBox
$grpActions.Text = 'Acoes'
$grpActions.Location = New-Object System.Drawing.Point(244, 72)
$grpActions.Size = New-Object System.Drawing.Size(914, 58)
$grpActions.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpActions)

$btnCheckHosts = New-Object System.Windows.Forms.Button
$btnCheckHosts.Text = 'Verificar hosts'
$btnCheckHosts.Location = New-Object System.Drawing.Point(10, 20)
$btnCheckHosts.Size = New-Object System.Drawing.Size(120, 28)
$grpActions.Controls.Add($btnCheckHosts)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Install CU'
$btnInstall.Location = New-Object System.Drawing.Point(136, 20)
$btnInstall.Size = New-Object System.Drawing.Size(120, 28)
$btnInstall.BackColor = [System.Drawing.Color]::FromArgb(220, 235, 252)
$grpActions.Controls.Add($btnInstall)

$lblMaxThreads = New-Object System.Windows.Forms.Label
$lblMaxThreads.Text = 'Paralelismo:'
$lblMaxThreads.Location = New-Object System.Drawing.Point(270, 25)
$lblMaxThreads.AutoSize = $true
$grpActions.Controls.Add($lblMaxThreads)

$numMaxThreads = New-Object System.Windows.Forms.NumericUpDown
$numMaxThreads.Minimum = 1
$numMaxThreads.Maximum = 50
$numMaxThreads.Value = 5
$numMaxThreads.Location = New-Object System.Drawing.Point(350, 22)
$numMaxThreads.Size = New-Object System.Drawing.Size(50, 24)
$grpActions.Controls.Add($numMaxThreads)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Exportar relatorio (CSV)'
$btnExport.Location = New-Object System.Drawing.Point(420, 20)
$btnExport.Size = New-Object System.Drawing.Size(160, 28)
$grpActions.Controls.Add($btnExport)

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Text = 'Sucesso: 0   Erro: 0   Pendente: 0'
$lblSummary.Location = New-Object System.Drawing.Point(600, 25)
$lblSummary.AutoSize = $true
$lblSummary.Anchor = 'Top,Left,Right'
$grpActions.Controls.Add($lblSummary)

# --- Grid principal ----------------------------------------------------------
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(244, 136)
$grid.Size = New-Object System.Drawing.Size(914, 570)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.SelectionMode = 'FullRowSelect'

$cols = @(
    @{ Name='Host';        Header='Host';           Width=110 },
    @{ Name='IP';          Header='IP';             Width=90  },
    @{ Name='Online';      Header='Online';         Width=60  },
    @{ Name='WinRM';       Header='WinRM';          Width=60  },
    @{ Name='Windows';     Header='Windows (build)';Width=140 },
    @{ Name='Disco';       Header='Disco livre';    Width=80  },
    @{ Name='Reboot';      Header='Reboot pend.';   Width=80  },
    @{ Name='KBInstalado'; Header='KB instalado';   Width=90  },
    @{ Name='Compat';      Header='Compativel';     Width=80  },
    @{ Name='Status';      Header='Status';         Width=100 },
    @{ Name='ExitCode';    Header='Exit code';      Width=70  },
    @{ Name='Detail';      Header='Detalhe';        Width=220 }
)
foreach ($c in $cols) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.Name
    $col.HeaderText = $c.Header
    $col.FillWeight = $c.Width
    $grid.Columns.Add($col) | Out-Null
}
$form.Controls.Add($grid)

# ===========================================================================
# FUNCOES DE APOIO A UI
# ===========================================================================

function Get-HostListFromTextBox {
    $txtHosts.Text -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
}

function Initialize-GridRows {
    $grid.Rows.Clear()
    $script:RowIndexByHost.Clear()
    $i = 0
    foreach ($h in (Get-HostListFromTextBox)) {
        $grid.Rows.Add($h, '', '', '', '', '', '', '', '', 'Pendente', '', '') | Out-Null
        $script:RowIndexByHost[$h] = $i
        $i++
    }
    Update-Summary
}

function Update-Summary {
    $ok = 0; $err = 0; $pend = 0
    foreach ($row in $grid.Rows) {
        switch ($row.Cells['Status'].Value) {
            'Sucesso'   { $ok++ }
            'Erro'      { $err++ }
            default     { $pend++ }
        }
    }
    $lblSummary.Text = "Sucesso: $ok   Erro: $err   Pendente/outros: $pend"
}

function Set-RowValues {
    param([string]$HostName, [hashtable]$Values)
    if (-not $script:RowIndexByHost.ContainsKey($HostName)) { return }
    $row = $grid.Rows[$script:RowIndexByHost[$HostName]]
    foreach ($k in $Values.Keys) {
        if ($row.Cells[$k] -ne $null) { $row.Cells[$k].Value = $Values[$k] }
    }
}

# Dispara N workers em paralelo usando um RunspacePool, guardando handles em $script:Jobs
function Start-ParallelWork {
    param(
        [scriptblock]$WorkerBlock,
        [string[]]$Hosts,
        [System.Collections.IDictionary]$CommonArgs,
        [string]$JobKind
    )

    # IMPORTANTE:
    # CommonArgs chega como [ordered] (OrderedDictionary). Nao converter para
    # [hashtable], pois a conversao perde a ordem e os argumentos sao enviados
    # ao worker por POSICAO via AddArgument().
    #
    # Exemplo do bug anterior:
    #   Worker espera: Credential, LocalFilePath, FileName, Extension, SyncHash
    #   Hashtable pode entregar: FileName, SyncHash, Credential, ...
    #   Resultado: LocalFilePath recebe um valor errado e Test-Path falha.
    #
    # Mantendo IDictionary, o OrderedDictionary original preserva a sequencia.

    if (-not $CommonArgs) {
        throw 'Start-ParallelWork recebeu CommonArgs vazio.'
    }

    $maxThreads = [int]$numMaxThreads.Value
    $script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, $maxThreads)
    $script:RunspacePool.Open()

    foreach ($h in $Hosts) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:RunspacePool
        [void]$ps.AddScript($WorkerBlock)

        # Primeiro argumento de todos os workers: HostName
        [void]$ps.AddArgument($h)

        # Os demais argumentos seguem EXATAMENTE a ordem declarada no [ordered]
        # de cada chamada (Preflight e Install).
        foreach ($entry in $CommonArgs.GetEnumerator()) {
            [void]$ps.AddArgument($entry.Value)
        }

        $handle = $ps.BeginInvoke()
        $script:Jobs.Add([PSCustomObject]@{
            HostName = $h
            PS       = $ps
            Handle   = $handle
            Kind     = $JobKind
        })
    }
}

# ===========================================================================
# EVENT HANDLERS
# ===========================================================================

$btnLoadHosts.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Arquivo de texto (*.txt)|*.txt|Todos os arquivos (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtHosts.Text = (Get-Content -Path $dlg.FileName -ErrorAction SilentlyContinue) -join "`r`n"
        Initialize-GridRows
    }
})

$btnCredential.Add_Click({
    $cred = Get-Credential -Message 'Credencial para conexao remota (deixe em branco para usar o contexto atual)'
    if ($cred) {
        $script:Credential = $cred
        $lblCredStatus.Text = "Credencial: $($cred.UserName)"
    }
})

$btnSelectFile.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Pacotes de update (*.msu;*.cab)|*.msu;*.cab|Todos os arquivos (*.*)|*.*'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:UpdateFilePath = $dlg.FileName
        $script:UpdateInfo = Get-UpdateFileInfo -Path $dlg.FileName
        $info = $script:UpdateInfo
        $kbText = if ($info.KB) { $info.KB } else { 'nao identificado' }
        $lblFileInfo.Text = "$($info.FileName)  |  KB: $kbText  |  Arch: $($info.Arch)  |  SO: $($info.OSHint)  |  $($info.SizeMB) MB"
    }
})

$btnCheckHosts.Add_Click({
    if ($grid.Rows.Count -eq 0) { Initialize-GridRows }
    if ($grid.Rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Carregue a lista de hosts primeiro.', 'PSHPatcher') | Out-Null
        return
    }
    $kb = if ($script:UpdateInfo) { $script:UpdateInfo.KB } else { $null }
    $hosts = Get-HostListFromTextBox
    foreach ($h in $hosts) { Set-RowValues -HostName $h -Values @{ Status='Verificando'; Detail='Iniciando verificacao...' } }

    Start-ParallelWork -WorkerBlock $script:PreflightWorker -Hosts $hosts -JobKind 'Preflight' -CommonArgs ([ordered]@{
        Credential      = $script:Credential
        KB              = $kb
        InventoryBlock  = $script:RemoteInventoryBlock
        SyncHash        = $script:SyncHash
    })
    $timer.Start()
})

$btnInstall.Add_Click({
    if (-not $script:UpdateFilePath) {
        [System.Windows.Forms.MessageBox]::Show('Selecione o arquivo de update (.msu/.cab) primeiro.', 'PSHPatcher') | Out-Null
        return
    }

    if (-not (Test-Path -LiteralPath $script:UpdateFilePath -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show(
            "O arquivo selecionado nao existe mais ou nao esta acessivel:`r`n`r`n$($script:UpdateFilePath)`r`n`r`nSelecione o pacote novamente.",
            'PSHPatcher - arquivo nao encontrado',
            'OK',
            'Error'
        ) | Out-Null
        return
    }
    if ($grid.Rows.Count -eq 0) { Initialize-GridRows }
    if ($grid.Rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Carregue a lista de hosts primeiro.', 'PSHPatcher') | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Instalar $($script:UpdateInfo.FileName) em $($grid.Rows.Count) host(s)?",
        'Confirmar instalacao', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $hosts = Get-HostListFromTextBox
    foreach ($h in $hosts) { Set-RowValues -HostName $h -Values @{ Status='Enfileirado'; Detail='Aguardando slot de execucao...' } }

    Start-ParallelWork -WorkerBlock $script:InstallWorker -Hosts $hosts -JobKind 'Install' -CommonArgs ([ordered]@{
        Credential     = $script:Credential
        LocalFilePath  = $script:UpdateFilePath
        FileName       = $script:UpdateInfo.FileName
        Extension      = $script:UpdateInfo.Extension
        SyncHash       = $script:SyncHash
    })
    $timer.Start()
})

$btnExport.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = "PSHPatcher-relatorio-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    if ($dlg.ShowDialog() -eq 'OK') {
        $rows = foreach ($row in $grid.Rows) {
            [PSCustomObject]@{
                Host = $row.Cells['Host'].Value; IP = $row.Cells['IP'].Value
                Online = $row.Cells['Online'].Value; WinRM = $row.Cells['WinRM'].Value
                Windows = $row.Cells['Windows'].Value; DiscoLivre = $row.Cells['Disco'].Value
                RebootPendente = $row.Cells['Reboot'].Value; KBInstalado = $row.Cells['KBInstalado'].Value
                Compativel = $row.Cells['Compat'].Value; Status = $row.Cells['Status'].Value
                ExitCode = $row.Cells['ExitCode'].Value; Detalhe = $row.Cells['Detail'].Value
            }
        }
        $rows | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show('Relatorio exportado.', 'PSHPatcher') | Out-Null
    }
})

$txtHosts.Add_Leave({ Initialize-GridRows })

# ===========================================================================
# TIMER - atualiza a grid com estagios em tempo real + resultados finais
# ===========================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 800

$timer.Add_Tick({
    # 1) Atualiza estagios "ao vivo" vindos do SyncHash (preenchidos pelos workers)
    foreach ($h in @($script:SyncHash.Keys)) {
        $s = $script:SyncHash[$h]
        Set-RowValues -HostName $h -Values @{ Status = $s.Status; Detail = $s.Detail }
    }

    # 2) Verifica jobs concluidos, coleta resultado final e limpa
    $stillRunning = New-Object System.Collections.Generic.List[object]
    foreach ($job in $script:Jobs) {
        if ($job.Handle.IsCompleted) {
            try {
                $result = $job.PS.EndInvoke($job.Handle)
            } catch {
                $result = $null
            }
            $job.PS.Dispose()

            if ($result) {
                if ($job.Kind -eq 'Preflight') {
                    $compat = if ($script:UpdateInfo) {
                        Test-Compatibility -UpdateInfo $script:UpdateInfo -RemoteOSCaption $result.OSCaption -RemoteArch $result.OSArch
                    } else { $null }
                    Set-RowValues -HostName $result.HostName -Values @{
                        Online      = if ($result.Online) { 'Sim' } else { 'Nao' }
                        WinRM       = if ($result.WinRM) { 'Sim' } else { 'Nao' }
                        Windows     = if ($result.BuildNumber) { "$($result.OSCaption) / $($result.BuildNumber)" } else { '' }
                        Disco       = if ($result.FreeDiskGB) { "$($result.FreeDiskGB) GB" } else { '' }
                        Reboot      = if ($result.PSObject.Properties['RebootPending']) { if ($result.RebootPending) {'Sim'} else {'Nao'} } else { '' }
                        KBInstalado = if ($result.PSObject.Properties['HasKB']) { if ($result.HasKB) {'Sim'} else {'Nao'} } else { '' }
                        Compat      = if ($compat -eq $null) { '' } elseif ($compat) { 'Sim' } else { 'Nao' }
                        Status      = $result.Status
                        Detail      = $result.Detail
                    }
                }
                elseif ($job.Kind -eq 'Install') {
                    $detail = Get-FriendlyExitDetail -ExitCode $result.ExitCode
                    if ($result.Status -eq 'Erro' -and $result.Detail) { $detail = $result.Detail }
                    if ($result.Status -eq 'Erro' -and $result.RemotePath) { $detail = "$detail (caminho: $($result.RemotePath))" }
                    Set-RowValues -HostName $result.HostName -Values @{
                        Status   = $result.Status
                        ExitCode = $result.ExitCode
                        Reboot   = if ($result.RebootPending) { 'Sim' } else { 'Nao' }
                        Detail   = $detail
                    }
                }
            }
            $script:SyncHash.Remove($job.HostName)
        } else {
            $stillRunning.Add($job)
        }
    }
    $script:Jobs.Clear()
    $script:Jobs.AddRange($stillRunning)

    Update-Summary

    if ($script:Jobs.Count -eq 0) {
        $timer.Stop()
        if ($script:RunspacePool) { $script:RunspacePool.Close(); $script:RunspacePool.Dispose(); $script:RunspacePool = $null }
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    foreach ($job in $script:Jobs) { try { $job.PS.Dispose() } catch {} }
    if ($script:RunspacePool) { try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch {} }
})

[void]$form.ShowDialog()
