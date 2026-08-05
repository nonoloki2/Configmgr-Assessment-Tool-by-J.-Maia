#Requires -Version 5.0
<#
    CM Collection Include Tool
    ---------------------------
    Interface grafica para o Configuration Manager (SCCM/MECM) que permite:
      1) Validar/selecionar uma Colecao de DESTINO (onde a regra sera criada)
      2) Validar/selecionar uma Colecao a ser INCLUIDA (Include Membership Rule)
      3) (Opcional) Adicionar 1 ou varios devices como Direct Membership Rule
         na colecao de destino

    Pre-requisitos:
      - Console do Configuration Manager instalado na maquina (ConfigurationManager.psd1)
      - Executar com uma conta que tenha permissao de "Modify Collection" no CM
      - Rodar o PowerShell (ISE ou console) - nao precisa ser Admin local,
        precisa sim de permissao dentro do CM
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------------------------------------------------
# Conexao com o site do Configuration Manager
# ----------------------------------------------------------------------

function Connect-CMSiteEnv {

    try {
        if (-not (Get-Module ConfigurationManager -ErrorAction SilentlyContinue)) {
            $modulePath = $null

            if ($env:SMS_ADMIN_UI_PATH) {
                $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1'
            }

            if (-not $modulePath -or -not (Test-Path $modulePath)) {
                $modulePath = "$($env:ProgramFiles)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
                if (-not (Test-Path $modulePath)) {
                    $modulePath = "${env:ProgramFiles(x86)}\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
                }
            }

            if (-not (Test-Path $modulePath)) {
                throw "Nao foi possivel localizar o modulo ConfigurationManager.psd1. Verifique se o Console do CM esta instalado nesta maquina."
            }

            Import-Module $modulePath -ErrorAction Stop
        }

        # Descobre o Site Code via WMI (SMS_ProviderLocation)
        $providerLoc = Get-CimInstance -Namespace 'root\sms' -ClassName 'SMS_ProviderLocation' -ErrorAction Stop | Select-Object -First 1

        if (-not $providerLoc) {
            throw "Nao foi possivel obter o Site Code via WMI (SMS_ProviderLocation)."
        }

        $siteCode = $providerLoc.SiteCode
        $siteServer = $providerLoc.Machine

        if (-not (Get-PSDrive -Name $siteCode -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name $siteCode -PSProvider CMSite -Root $siteServer -ErrorAction Stop | Out-Null
        }

        Set-Location "$($siteCode):\" -ErrorAction Stop

        return [PSCustomObject]@{
            Success    = $true
            SiteCode   = $siteCode
            SiteServer = $siteServer
            Message    = "Conectado ao site $siteCode ($siteServer)."
        }
    }
    catch {
        return [PSCustomObject]@{
            Success    = $false
            SiteCode   = $null
            SiteServer = $null
            Message    = $_.Exception.Message
        }
    }
}

# ----------------------------------------------------------------------
# Helpers de colecao
# ----------------------------------------------------------------------

function Find-CMCollectionByName {
    param([string]$Name)

    if (-not $Name) { return $null }

    # busca exata primeiro; se nao achar, tenta "contem"
    $col = Get-CMCollection -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $col) {
        $col = Get-CMCollection -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$Name*" } |
            Select-Object -First 1
    }

    return $col
}

function Get-CollectionTypeText {
    param([int]$CollectionType)
    switch ($CollectionType) {
        1 { return 'User' }
        2 { return 'Device' }
        default { return 'Desconhecido' }
    }
}

# ----------------------------------------------------------------------
# Interface Grafica
# ----------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "CM Collection Include Tool"
$form.Size = New-Object System.Drawing.Size(780, 660)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(700, 600)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# --- status de conexao ---
$lblConn = New-Object System.Windows.Forms.Label
$lblConn.Text = "Nao conectado ao site do Configuration Manager."
$lblConn.Location = New-Object System.Drawing.Point(15, 12)
$lblConn.Size = New-Object System.Drawing.Size(600, 20)
$lblConn.ForeColor = [System.Drawing.Color]::DarkRed
$form.Controls.Add($lblConn)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Conectar ao Site"
$btnConnect.Location = New-Object System.Drawing.Point(630, 8)
$btnConnect.Size = New-Object System.Drawing.Size(120, 26)
$btnConnect.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnConnect)

# --- separador visual ---
$sep1 = New-Object System.Windows.Forms.Label
$sep1.BorderStyle = "Fixed3D"
$sep1.Location = New-Object System.Drawing.Point(15, 42)
$sep1.Size = New-Object System.Drawing.Size(735, 2)
$sep1.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($sep1)

# --- Colecao de DESTINO ---
$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Text = "1) Colecao de DESTINO (onde a regra sera criada):"
$lblTarget.Location = New-Object System.Drawing.Point(15, 55)
$lblTarget.AutoSize = $true
$form.Controls.Add($lblTarget)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(15, 78)
$txtTarget.Size = New-Object System.Drawing.Size(500, 24)
$txtTarget.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtTarget)

$btnValidateTarget = New-Object System.Windows.Forms.Button
$btnValidateTarget.Text = "Validar"
$btnValidateTarget.Location = New-Object System.Drawing.Point(525, 77)
$btnValidateTarget.Size = New-Object System.Drawing.Size(100, 26)
$btnValidateTarget.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnValidateTarget)

$lblTargetResult = New-Object System.Windows.Forms.Label
$lblTargetResult.Text = "Status: nao validado."
$lblTargetResult.Location = New-Object System.Drawing.Point(15, 106)
$lblTargetResult.Size = New-Object System.Drawing.Size(735, 20)
$lblTargetResult.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblTargetResult.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblTargetResult)

# --- separador visual ---
$sep2 = New-Object System.Windows.Forms.Label
$sep2.BorderStyle = "Fixed3D"
$sep2.Location = New-Object System.Drawing.Point(15, 136)
$sep2.Size = New-Object System.Drawing.Size(735, 2)
$sep2.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($sep2)

# --- Colecao a INCLUIR ---
$lblInclude = New-Object System.Windows.Forms.Label
$lblInclude.Text = "2) Colecao a ser INCLUIDA na colecao de destino:"
$lblInclude.Location = New-Object System.Drawing.Point(15, 148)
$lblInclude.AutoSize = $true
$form.Controls.Add($lblInclude)

$txtInclude = New-Object System.Windows.Forms.TextBox
$txtInclude.Location = New-Object System.Drawing.Point(15, 171)
$txtInclude.Size = New-Object System.Drawing.Size(500, 24)
$txtInclude.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtInclude)

$btnValidateInclude = New-Object System.Windows.Forms.Button
$btnValidateInclude.Text = "Validar"
$btnValidateInclude.Location = New-Object System.Drawing.Point(525, 170)
$btnValidateInclude.Size = New-Object System.Drawing.Size(100, 26)
$btnValidateInclude.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnValidateInclude)

$lblIncludeResult = New-Object System.Windows.Forms.Label
$lblIncludeResult.Text = "Status: nao validado."
$lblIncludeResult.Location = New-Object System.Drawing.Point(15, 199)
$lblIncludeResult.Size = New-Object System.Drawing.Size(735, 20)
$lblIncludeResult.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblIncludeResult.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblIncludeResult)

$btnDoInclude = New-Object System.Windows.Forms.Button
$btnDoInclude.Text = "Incluir Colecao na Colecao de Destino"
$btnDoInclude.Location = New-Object System.Drawing.Point(15, 226)
$btnDoInclude.Size = New-Object System.Drawing.Size(300, 30)
$btnDoInclude.BackColor = [System.Drawing.Color]::LightSteelBlue
$form.Controls.Add($btnDoInclude)

# --- separador visual ---
$sep3 = New-Object System.Windows.Forms.Label
$sep3.BorderStyle = "Fixed3D"
$sep3.Location = New-Object System.Drawing.Point(15, 270)
$sep3.Size = New-Object System.Drawing.Size(735, 2)
$sep3.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($sep3)

# --- Devices (opcional) ---
$lblDevices = New-Object System.Windows.Forms.Label
$lblDevices.Text = "3) (Opcional) Adicionar device(s) na colecao de DESTINO - um nome por linha ou separados por virgula:"
$lblDevices.Location = New-Object System.Drawing.Point(15, 282)
$lblDevices.AutoSize = $true
$form.Controls.Add($lblDevices)

$txtDevices = New-Object System.Windows.Forms.TextBox
$txtDevices.Location = New-Object System.Drawing.Point(15, 305)
$txtDevices.Size = New-Object System.Drawing.Size(735, 90)
$txtDevices.Multiline = $true
$txtDevices.ScrollBars = "Vertical"
$txtDevices.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtDevices)

$btnAddDevices = New-Object System.Windows.Forms.Button
$btnAddDevices.Text = "Adicionar Device(s) como Direct Membership Rule"
$btnAddDevices.Location = New-Object System.Drawing.Point(15, 402)
$btnAddDevices.Size = New-Object System.Drawing.Size(320, 30)
$form.Controls.Add($btnAddDevices)

# --- separador visual ---
$sep4 = New-Object System.Windows.Forms.Label
$sep4.BorderStyle = "Fixed3D"
$sep4.Location = New-Object System.Drawing.Point(15, 444)
$sep4.Size = New-Object System.Drawing.Size(735, 2)
$sep4.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($sep4)

# --- Log ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Log:"
$lblLog.Location = New-Object System.Drawing.Point(15, 452)
$lblLog.AutoSize = $true
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 474)
$txtLog.Size = New-Object System.Drawing.Size(735, 130)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::White
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtLog)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Pronto."
$statusStrip.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusStrip)

function Write-Log {
    param([string]$Text, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'HH:mm:ss'
    $txtLog.AppendText("[$timestamp] [$Level] $Text`r`n")
    $statusLabel.Text = $Text
}

# guarda os objetos de colecao validados
$script:targetCollection = $null
$script:includeCollection = $null

# ----------------------------------------------------------------------
# Eventos
# ----------------------------------------------------------------------

$btnConnect.Add_Click({
    $btnConnect.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Write-Log "Conectando ao site do Configuration Manager..."
    $form.Refresh()

    $result = Connect-CMSiteEnv

    $form.Cursor = [System.Windows.Forms.Cursors]::Default
    $btnConnect.Enabled = $true

    if ($result.Success) {
        $lblConn.Text = "Conectado: $($result.Message)"
        $lblConn.ForeColor = [System.Drawing.Color]::DarkGreen
        Write-Log $result.Message
    } else {
        $lblConn.Text = "Falha na conexao. Veja o log."
        $lblConn.ForeColor = [System.Drawing.Color]::DarkRed
        Write-Log $result.Message 'ERRO'
        [System.Windows.Forms.MessageBox]::Show($result.Message, "Erro de conexao", "OK", "Error") | Out-Null
    }
})

$btnValidateTarget.Add_Click({
    $name = $txtTarget.Text.Trim()
    if (-not $name) {
        $lblTargetResult.Text = "Digite um nome de colecao."
        $lblTargetResult.ForeColor = [System.Drawing.Color]::DarkRed
        return
    }

    Write-Log "Validando colecao de destino: $name"
    $col = Find-CMCollectionByName -Name $name

    if ($col) {
        $script:targetCollection = $col
        $typeTxt = Get-CollectionTypeText -CollectionType $col.CollectionType
        $lblTargetResult.Text = "OK -> '$($col.Name)'  [ID: $($col.CollectionID)]  Tipo: $typeTxt  Membros: $($col.MemberCount)"
        $lblTargetResult.ForeColor = [System.Drawing.Color]::DarkGreen
        Write-Log "Colecao de destino validada: $($col.Name) ($($col.CollectionID))"
    } else {
        $script:targetCollection = $null
        $lblTargetResult.Text = "Colecao nao encontrada."
        $lblTargetResult.ForeColor = [System.Drawing.Color]::DarkRed
        Write-Log "Colecao de destino NAO encontrada: $name" 'ERRO'
    }
})

$btnValidateInclude.Add_Click({
    $name = $txtInclude.Text.Trim()
    if (-not $name) {
        $lblIncludeResult.Text = "Digite um nome de colecao."
        $lblIncludeResult.ForeColor = [System.Drawing.Color]::DarkRed
        return
    }

    Write-Log "Validando colecao a incluir: $name"
    $col = Find-CMCollectionByName -Name $name

    if ($col) {
        $script:includeCollection = $col
        $typeTxt = Get-CollectionTypeText -CollectionType $col.CollectionType
        $lblIncludeResult.Text = "OK -> '$($col.Name)'  [ID: $($col.CollectionID)]  Tipo: $typeTxt  Membros: $($col.MemberCount)"
        $lblIncludeResult.ForeColor = [System.Drawing.Color]::DarkGreen
        Write-Log "Colecao a incluir validada: $($col.Name) ($($col.CollectionID))"
    } else {
        $script:includeCollection = $null
        $lblIncludeResult.Text = "Colecao nao encontrada."
        $lblIncludeResult.ForeColor = [System.Drawing.Color]::DarkRed
        Write-Log "Colecao a incluir NAO encontrada: $name" 'ERRO'
    }
})

$btnDoInclude.Add_Click({
    if (-not $script:targetCollection) {
        [System.Windows.Forms.MessageBox]::Show("Valide primeiro a colecao de DESTINO.", "Atencao", "OK", "Warning") | Out-Null
        return
    }
    if (-not $script:includeCollection) {
        [System.Windows.Forms.MessageBox]::Show("Valide primeiro a colecao a ser INCLUIDA.", "Atencao", "OK", "Warning") | Out-Null
        return
    }

    $target = $script:targetCollection
    $include = $script:includeCollection

    if ($target.CollectionID -eq $include.CollectionID) {
        [System.Windows.Forms.MessageBox]::Show("A colecao de destino e a colecao a incluir nao podem ser a mesma.", "Atencao", "OK", "Warning") | Out-Null
        return
    }

    if ($target.CollectionType -ne $include.CollectionType) {
        [System.Windows.Forms.MessageBox]::Show("Tipos incompativeis: nao e possivel incluir uma colecao de $(Get-CollectionTypeText $include.CollectionType) dentro de uma colecao de $(Get-CollectionTypeText $target.CollectionType).", "Tipos incompativeis", "OK", "Error") | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Confirma incluir a colecao:`r`n  '$($include.Name)' ($($include.CollectionID))`r`n`r`ndentro de:`r`n  '$($target.Name)' ($($target.CollectionID)) ?",
        "Confirmar inclusao", "YesNo", "Question")

    if ($confirm -ne "Yes") { return }

    try {
        Write-Log "Incluindo '$($include.Name)' em '$($target.Name)'..."

        if ($target.CollectionType -eq 2) {
            Add-CMDeviceCollectionIncludeMembershipRule -CollectionId $target.CollectionID -IncludeCollectionId $include.CollectionID -ErrorAction Stop
        } else {
            Add-CMUserCollectionIncludeMembershipRule -CollectionId $target.CollectionID -IncludeCollectionId $include.CollectionID -ErrorAction Stop
        }

        Write-Log "Regra de inclusao criada com sucesso."
        [System.Windows.Forms.MessageBox]::Show("Colecao incluida com sucesso!`r`n`r`nLembre-se: a atualizacao de membros pode levar alguns minutos (ou force um 'Update Membership' na colecao de destino).", "Sucesso", "OK", "Information") | Out-Null
    }
    catch {
        Write-Log "Erro ao incluir colecao: $($_.Exception.Message)" 'ERRO'
        [System.Windows.Forms.MessageBox]::Show("Erro ao incluir colecao:`r`n`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
})

$btnAddDevices.Add_Click({
    if (-not $script:targetCollection) {
        [System.Windows.Forms.MessageBox]::Show("Valide primeiro a colecao de DESTINO.", "Atencao", "OK", "Warning") | Out-Null
        return
    }

    if ($script:targetCollection.CollectionType -ne 2) {
        [System.Windows.Forms.MessageBox]::Show("A colecao de destino nao e uma colecao de Devices.", "Atencao", "OK", "Warning") | Out-Null
        return
    }

    $raw = $txtDevices.Text
    if (-not $raw.Trim()) {
        [System.Windows.Forms.MessageBox]::Show("Informe ao menos um nome de device.", "Atencao", "OK", "Warning") | Out-Null
        return
    }

    $names = $raw -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $names = $names | Select-Object -Unique

    if (-not $names) {
        [System.Windows.Forms.MessageBox]::Show("Nenhum nome valido informado.", "Atencao", "OK", "Warning") | Out-Null
        return
    }

    $target = $script:targetCollection
    $success = 0
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($deviceName in $names) {
        try {
            $device = Get-CMDevice -Name $deviceName -Fast -ErrorAction SilentlyContinue | Select-Object -First 1

            if (-not $device) {
                $failed.Add("$deviceName (nao encontrado no CM)")
                Write-Log "Device nao encontrado: $deviceName" 'ERRO'
                continue
            }

            Add-CMDeviceCollectionDirectMembershipRule -CollectionId $target.CollectionID -ResourceId $device.ResourceID -ErrorAction Stop
            $success++
            Write-Log "Device adicionado: $deviceName (ResourceID $($device.ResourceID))"
        }
        catch {
            $failed.Add("$deviceName ($($_.Exception.Message))")
            Write-Log "Erro ao adicionar $deviceName : $($_.Exception.Message)" 'ERRO'
        }
    }

    $msg = "Devices adicionados com sucesso: $success de $($names.Count)."
    if ($failed.Count -gt 0) {
        $msg += "`r`n`r`nFalhas:`r`n" + ($failed -join "`r`n")
        [System.Windows.Forms.MessageBox]::Show($msg, "Concluido com falhas", "OK", "Warning") | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show($msg, "Concluido", "OK", "Information") | Out-Null
    }
})

# ----------------------------------------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
