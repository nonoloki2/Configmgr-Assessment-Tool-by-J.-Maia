<#
==============================================================================
 SCCM-AppCreator.ps1
==============================================================================
 Interface grafica (Windows Forms) para automatizar a criacao de Aplicacoes
 no SCCM baseadas em scripts (install/uninstall .ps1 ou .bat) com deteccao
 via PowerShell lendo o registro de Uninstall (64-bit, WOW6432Node e HKCU).

 REQUISITOS:
   - Executar em uma maquina com o Console do SCCM instalado (fornece o
     modulo ConfigurationManager.psd1 via variavel de ambiente SMS_ADMIN_UI_PATH)
   - Permissao de criacao de aplicacoes no SCCM para o usuario logado
   - PowerShell 5.1+ (Windows PowerShell), executado com permissao adequada

 FLUXO ESPERADO:
   1. Testar instalacao/desinstalacao manualmente na maquina teste (voce ja faz isso)
   2. Colocar na pasta de origem (source):
        - O instalador (exe/msi) e os arquivos que os scripts precisam
        - install.ps1 ou install.bat
        - uninstall.ps1 ou uninstall.bat
   3. Abrir esta ferramenta, conectar no site, apontar a pasta, escanear
   4. (Opcional) Validar instalacao/desinstalacao/deteccao na propria maquina teste
   5. Criar a aplicacao no SCCM com um clique
==============================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ----------------------------------------------------------------------------
# FUNCOES DE LOGICA (separadas da GUI para poderem ser reaproveitadas/testadas)
# ----------------------------------------------------------------------------

function Get-CleanPath {
    <#
        Normaliza caminhos colados de fontes como a barra de enderecos do
        Explorer. O Windows envolve o caminho em aspas quando ele contem
        espacos (comum em nomes de pasta), e isso vira parte literal da
        string ao colar - o Test-Path falha silenciosamente por causa disso.
        Remove tambem espacos/quebras de linha nas pontas e uma barra final.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $clean = $Path.Trim()
    # Remove aspas retas e "curvas" (tipograficas) nas pontas, se existirem
    $clean = $clean.Trim([char]'"', [char]"'", [char]0x201C, [char]0x201D, [char]0x2018, [char]0x2019)
    $clean = $clean.Trim()
    # Remove barra invertida final (exceto se for so a raiz "\\servidor\share")
    if ($clean.Length -gt 2 -and $clean.EndsWith('\')) {
        $clean = $clean.TrimEnd('\')
    }
    return $clean
}

function Get-SourceManifestViaInteractiveSession {
    <#
        Le SOMENTE o inventario da raiz da pasta de origem usando o usuario
        interativo da MESMA sessao onde esta GUI esta aberta.

        IMPORTANTE:
        - nao copia o pacote;
        - nao altera o UNC original;
        - primeiro ENUMERA a pasta com Get-ChildItem -ErrorAction Stop;
        - somente depois decide se install/uninstall existem;
        - se o UNC nao puder ser enumerado, retorna ERRO DE ACESSO em vez de
          fingir que os arquivos nao existem.
    #>
    param([Parameter(Mandatory)][string]$SourcePath)

    try {
        $guiSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
        $allExplorers = @(Get-Process -Name explorer -IncludeUserName -ErrorAction Stop |
            Where-Object { $_.UserName })

        # Prioridade absoluta: Explorer da MESMA sessao da GUI.
        $explorerProc = $allExplorers |
            Where-Object { $_.SessionId -eq $guiSessionId } |
            Select-Object -First 1

        # Fallback apenas se a GUI estiver em uma sessao sem explorer.exe.
        if (-not $explorerProc) {
            $explorerProc = $allExplorers |
                Sort-Object StartTime -Descending |
                Select-Object -First 1
        }
    }
    catch {
        return [pscustomobject]@{
            Sucesso=$false
            Mensagem="Nao foi possivel identificar o usuario da sessao interativa: $($_.Exception.Message)"
        }
    }

    if (-not $explorerProc -or -not $explorerProc.UserName) {
        return [pscustomobject]@{
            Sucesso=$false
            Mensagem='Nenhuma sessao interativa com explorer.exe foi encontrada.'
        }
    }

    $interactiveUser = [string]$explorerProc.UserName
    $interactiveSessionId = [int]$explorerProc.SessionId
    $token = [guid]::NewGuid().ToString('N')
    $taskName = "SCCMAppCreator_Scan_$($token.Substring(0,8))"
    $helperScript = Join-Path $env:TEMP "$taskName.ps1"
    $resultFile = Join-Path $env:TEMP "$taskName.json"

    $safeSource = $SourcePath.Replace("'", "''")
    $safeResult = $resultFile.Replace("'", "''")

    $helperContent = @"
`$ErrorActionPreference = 'Stop'
try {
    `$root = '$safeSource'

    # Enumerar a raiz e obrigar erro real caso o UNC nao esteja acessivel.
    `$items = @(Get-ChildItem -LiteralPath `$root -Force -File -ErrorAction Stop)
    `$names = @(`$items | ForEach-Object { [string]`$_.Name })
    `$lower = @(`$names | ForEach-Object { `$_.ToLowerInvariant() })

    `$result = [ordered]@{
        Success = `$true
        Error = `$null
        Root = `$root
        Files = `$names
        InstallPs1 = (`$lower -contains 'install.ps1')
        InstallBat = (`$lower -contains 'install.bat')
        UninstallPs1 = (`$lower -contains 'uninstall.ps1')
        UninstallBat = (`$lower -contains 'uninstall.bat')
    }
}
catch {
    `$result = [ordered]@{
        Success = `$false
        Error = `$_.Exception.Message
        Root = '$safeSource'
        Files = @()
        InstallPs1 = `$false
        InstallBat = `$false
        UninstallPs1 = `$false
        UninstallBat = `$false
    }
}
`$result | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath '$safeResult' -Encoding UTF8 -Force
"@

    try {
        Set-Content -LiteralPath $helperScript -Value $helperContent -Encoding UTF8 -Force
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$helperScript`""
        $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        $deadline = [datetime]::UtcNow.AddSeconds(30)
        while ([datetime]::UtcNow -lt $deadline -and -not (Test-Path -LiteralPath $resultFile)) {
            Start-Sleep -Milliseconds 300
        }

        if (-not (Test-Path -LiteralPath $resultFile)) {
            return [pscustomobject]@{
                Sucesso=$false
                Mensagem="A leitura da pasta nao retornou em 30 segundos como '$interactiveUser' (sessao $interactiveSessionId)."
            }
        }

        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.Success) {
            return [pscustomobject]@{
                Sucesso=$false
                Mensagem="O usuario '$interactiveUser' (sessao $interactiveSessionId) NAO conseguiu enumerar o UNC '$SourcePath'. Erro real: $($result.Error)"
            }
        }

        function New-ManifestCommandInfo {
            param([bool]$Ps1,[bool]$Bat,[string]$Action)
            if ($Ps1) {
                return [pscustomobject]@{ Encontrado=$true; Tipo='PowerShell'; Arquivo="$Action.ps1"; Comando="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$Action.ps1`"" }
            }
            if ($Bat) {
                return [pscustomobject]@{ Encontrado=$true; Tipo='Batch'; Arquivo="$Action.bat"; Comando="cmd.exe /c `".\$Action.bat`"" }
            }
            return [pscustomobject]@{ Encontrado=$false; Tipo=$null; Arquivo=$null; Comando=$null }
        }

        $filesFound = @($result.Files)
        $fileSummary = if ($filesFound.Count -gt 0) { $filesFound -join ', ' } else { '<pasta vazia>' }

        return [pscustomobject]@{
            Sucesso = $true
            Mensagem = "UNC enumerado com sucesso como '$interactiveUser' (sessao $interactiveSessionId). Arquivos na raiz: $fileSummary"
            InstallInfo = New-ManifestCommandInfo -Ps1 ([bool]$result.InstallPs1) -Bat ([bool]$result.InstallBat) -Action 'install'
            UninstallInfo = New-ManifestCommandInfo -Ps1 ([bool]$result.UninstallPs1) -Bat ([bool]$result.UninstallBat) -Action 'uninstall'
            Files = $filesFound
        }
    }
    catch {
        return [pscustomobject]@{ Sucesso=$false; Mensagem=$_.Exception.Message }
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $helperScript -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    }
}


function Resolve-SourceAccess {
    <#
        Garante acesso de LEITURA a pasta de origem para fins de escaneamento/teste.

        Se $Credential for informado, mapeia um PSDrive temporario usando essa
        credencial (util quando o script roda com uma conta de servico/SCCM
        que nao tem permissao no share de arquivos, mas o usuario tem).

        Retorna um objeto com:
          Sucesso           - bool
          CaminhoEfetivo    - caminho a usar para Test-Path/Get-ChildItem/Copy-Item
          Mensagem          - detalhe do erro, se houver

        O caminho original (UNC real) deve ser guardado a parte para uso no
        -ContentLocation do SCCM, que nao deve usar o drive temporario.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Management.Automation.PSCredential]$Credential
    )

    # Remove mapeamento anterior, se existir, para evitar conflito de nome
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }

    if ($Credential) {
        try {
            New-PSDrive -Name 'SCCMSRC' -PSProvider FileSystem -Root $Path -Credential $Credential -Scope Global -ErrorAction Stop | Out-Null
            return [PSCustomObject]@{ Sucesso = $true; CaminhoEfetivo = 'SCCMSRC:\'; Mensagem = "Acesso via credencial alternativa OK." }
        }
        catch {
            return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = $_.Exception.Message }
        }
    }
    else {
        if (Test-Path -LiteralPath $Path) {
            return [PSCustomObject]@{ Sucesso = $true; CaminhoEfetivo = $Path; Mensagem = "Acesso com a conta atual OK." }
        }
        else {
            return [PSCustomObject]@{ Sucesso = $false; CaminhoEfetivo = $null; Mensagem = "Test-Path retornou falso (sem detalhe de erro adicional)." }
        }
    }
}


function Get-InstallCommandLine {
    <#
        Verifica na pasta de origem se existe install.ps1/uninstall.ps1 ou
        install.bat/uninstall.bat e retorna a linha de comando pronta para
        os campos "Program"/"Uninstall Program" do SCCM.
        Prioridade: .ps1 primeiro, depois .bat.
    #>
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)][ValidateSet('install','uninstall')][string]$Action
    )

    $ps1Path = Join-Path $FolderPath "$Action.ps1"
    $batPath = Join-Path $FolderPath "$Action.bat"

    if (Test-Path -LiteralPath $ps1Path) {
        return [PSCustomObject]@{
            Encontrado = $true
            Tipo       = 'PowerShell'
            Arquivo    = "$Action.ps1"
            Comando    = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$Action.ps1`""
        }
    }
    elseif (Test-Path -LiteralPath $batPath) {
        return [PSCustomObject]@{
            Encontrado = $true
            Tipo       = 'Batch'
            Arquivo    = "$Action.bat"
            Comando    = "cmd.exe /c `".\$Action.bat`""
        }
    }
    else {
        return [PSCustomObject]@{
            Encontrado = $false
            Tipo       = $null
            Arquivo    = $null
            Comando    = $null
        }
    }
}

function New-DetectionScriptText {
    <#
        Gera Detection Method a partir do DisplayName e DisplayVersion REAIS
        descobertos na maquina teste. Nao depende dos campos digitados para
        localizar o software.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayNamePattern,
        [Parameter(Mandatory)][string]$MinVersion
    )

    $safeName = $DisplayNamePattern.Replace("'", "''")
    $safeVersion = $MinVersion.Replace("'", "''")

    return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$expectedName = '$safeName'
`$expectedVersionText = '$safeVersion'

function Normalize-AppName([string]`$Name) {
    if ([string]::IsNullOrWhiteSpace(`$Name)) { return '' }
    return ((`$Name.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

function Convert-AppVersion([string]`$Text) {
    if ([string]::IsNullOrWhiteSpace(`$Text)) { return `$null }
    `$m = [regex]::Match(`$Text, '\d+(?:\.\d+){0,3}')
    if (-not `$m.Success) { return `$null }
    `$parts = @(`$m.Value.Split('.') | ForEach-Object { [int]`$_ })
    while (`$parts.Count -lt 2) { `$parts += 0 }
    while (`$parts.Count -lt 4) { `$parts += 0 }
    try { return [version]::new(`$parts[0],`$parts[1],`$parts[2],`$parts[3]) } catch { return `$null }
}

`$expectedNormalized = Normalize-AppName `$expectedName
`$minimum = Convert-AppVersion `$expectedVersionText
if (-not `$minimum) { exit 0 }

`$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
}
Get-ChildItem -Path 'HKU:\' -ErrorAction SilentlyContinue |
    Where-Object { `$_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
    ForEach-Object { `$uninstallPaths += "HKU:\`$(`$_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" }

foreach (`$app in (Get-ItemProperty -Path `$uninstallPaths -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace([string]`$app.DisplayName) -or [string]::IsNullOrWhiteSpace([string]`$app.DisplayVersion)) { continue }
    `$actualNormalized = Normalize-AppName ([string]`$app.DisplayName)
    if (`$actualNormalized -ne `$expectedNormalized) { continue }
    `$installed = Convert-AppVersion ([string]`$app.DisplayVersion)
    if (`$installed -and `$installed -ge `$minimum) {
        Write-Output 'Instalado'
        exit 0
    }
}
"@
}


function New-FileDetectionScriptText {
    <#
        Gera o TEXTO do script de deteccao baseado na EXISTENCIA (e
        opcionalmente na versao) de um arquivo executavel especifico.
        Usar quando o instalador nao grava nenhuma entrada em Uninstall
        (nem HKLM, nem HKCU/HKU) - por exemplo instaladores portáteis ou
        que copiam arquivos sem registrar nada no Windows Installer.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$MinVersion = ''
    )

    if ([string]::IsNullOrWhiteSpace($MinVersion)) {
        return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$caminho = '$FilePath'
if (Test-Path -LiteralPath `$caminho) {
    Write-Output "Instalado"
}
"@
    }

    return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$caminho = '$FilePath'
`$minVersion = [version]'$MinVersion'
if (Test-Path -LiteralPath `$caminho) {
    try {
        `$fileVersionRaw = (Get-Item -LiteralPath `$caminho).VersionInfo.FileVersion
        `$fv = [version](`$fileVersionRaw -replace '[^0-9.]', '')
        if (`$fv -ge `$minVersion) {
            Write-Output "Instalado"
        }
    }
    catch {
        # Se o arquivo nao tiver informacao de versao legivel, considera
        # instalado apenas pela existencia (mais permissivo que falhar).
        Write-Output "Instalado"
    }
}
"@
}

function Connect-ToSCCM {
    param(
        [Parameter(Mandatory)][string]$SiteServer,
        [Parameter(Mandatory)][string]$SiteCode
    )

    try {
        if (-not $env:SMS_ADMIN_UI_PATH) {
            throw "Variavel SMS_ADMIN_UI_PATH nao encontrada. O Console do SCCM precisa estar instalado nesta maquina."
        }

        if (-not (Get-Module ConfigurationManager)) {
            $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1'
            Import-Module $modulePath -ErrorAction Stop
        }

        if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
        }

        Set-Location "$($SiteCode):\"
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Conectado a $SiteServer ($SiteCode)" }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = $_.Exception.Message }
    }
}

function Get-CMAppCreatorHelperScriptText {
    <#
        Helper permanente do SCCM App Creator.
        Ele e executado pelo recurso Run Scripts do Configuration Manager no
        cliente alvo. O script roda no contexto do cliente SCCM (SYSTEM), sem
        WinRM, sem LAPS e sem CyberArk para a maquina teste.
    #>

    return @'
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Ping','RunSourceScript','InventoryInstalledSoftware','FindExecutable','RunRegistryDetection','RunFileDetection')]
    [string]$Action,

    [string]$SourcePath = '',
    [string]$ScriptType = '',
    [string]$ScriptFile = '',
    [string]$NamePattern = '',
    [string]$ExtraRoots = '',
    [string]$DisplayNamePattern = '',
    [string]$MinVersion = '',
    [string]$FilePath = ''
)

$ErrorActionPreference = 'Stop'

function Get-ExecutionIdentity {
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
    catch { return (& whoami.exe 2>$null) }
}

function Get-UninstallPathsIncludingHKU {
    <#
        Monta a lista de caminhos de registro Uninstall a varrer: HKLM nativo,
        HKLM WOW6432Node (apps 32-bit em SO 64-bit), HKCU do processo atual
        (irrelevante quando rodando como SYSTEM, mas nao custa incluir) e,
        principalmente, HKEY_USERS de cada hive de usuario carregado - onde
        ficam instalacoes "so para o usuario atual" (ALLUSERS != 1 no MSI),
        que sao invisiveis para o SYSTEM olhando so HKLM.
    #>
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    try {
        if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
        }
        $userHives = Get-ChildItem -Path 'HKU:\' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }
        foreach ($hive in $userHives) {
            $paths += "HKU:\$($hive.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
        }
    }
    catch { }

    return $paths
}

switch ($Action) {
    'Ping' {
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Identity     = Get-ExecutionIdentity
            Timestamp    = (Get-Date).ToString('s')
            Mode         = 'SCCM Run Script'
        } | ConvertTo-Json -Compress
    }

    'RunRegistryDetection' {
        <#
            Recebe so DisplayNamePattern e MinVersion (strings curtas) em vez
            de um script inteiro em Base64 - o recurso Run Scripts do SCCM
            tem limite de tamanho de parametro, e o script de deteccao
            completo (com a varredura de HKU) estourava esse limite,
            fazendo a deteccao "rodar em branco" sem erro nenhum.
        #>
        if ([string]::IsNullOrWhiteSpace($DisplayNamePattern)) { throw 'DisplayNamePattern nao informado.' }
        if ([string]::IsNullOrWhiteSpace($MinVersion)) { throw 'MinVersion nao informado.' }

        $minVer = $null
        try { $minVer = [version]$MinVersion } catch { throw "MinVersion invalido: '$MinVersion'" }

        $uninstallPaths = Get-UninstallPathsIncludingHKU

        $candidatos = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$DisplayNamePattern*" -and $_.DisplayVersion }

        $detected = $false
        $detalhes = New-Object System.Collections.Generic.List[string]
        foreach ($c in $candidatos) {
            $detalhes.Add("DisplayName='$($c.DisplayName)' DisplayVersion='$($c.DisplayVersion)' Path=$($c.PSPath)")
            try {
                $iv = [version](($c.DisplayVersion) -replace '[^0-9.]', '')
                if ($iv -ge $minVer) { $detected = $true }
            }
            catch { }
        }

        [PSCustomObject]@{
            ComputerName     = $env:COMPUTERNAME
            Identity         = Get-ExecutionIdentity
            Result           = if ($detected) { 'Instalado' } else { 'NaoInstalado' }
            Correspondencias = $detalhes
        } | ConvertTo-Json -Compress -Depth 3
    }

    'RunFileDetection' {
        if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'FilePath nao informado.' }

        $existe = Test-Path -LiteralPath $FilePath
        $versaoArquivo = $null
        $detected = $false

        if ($existe) {
            if ([string]::IsNullOrWhiteSpace($MinVersion)) {
                $detected = $true
            }
            else {
                try {
                    $versaoArquivo = (Get-Item -LiteralPath $FilePath).VersionInfo.FileVersion
                    $fv = [version](($versaoArquivo) -replace '[^0-9.]', '')
                    $minVer = [version]$MinVersion
                    if ($fv -ge $minVer) { $detected = $true }
                }
                catch {
                    # Sem info de versao legivel no arquivo: considera instalado so pela existencia.
                    $detected = $true
                }
            }
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Identity     = Get-ExecutionIdentity
            Existe       = $existe
            FileVersion  = $versaoArquivo
            Result       = if ($detected) { 'Instalado' } else { 'NaoInstalado' }
        } | ConvertTo-Json -Compress
    }

    'RunSourceScript' {
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'SourcePath nao informado.' }
        if ([string]::IsNullOrWhiteSpace($ScriptFile)) { throw 'ScriptFile nao informado.' }
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            throw "SYSTEM nao conseguiu acessar a pasta de origem: $SourcePath"
        }

        Push-Location -LiteralPath $SourcePath
        try {
            if ($ScriptType -eq 'PowerShell') {
                $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $SourcePath $ScriptFile) 2>&1 | Out-String
            }
            elseif ($ScriptType -eq 'Batch') {
                $output = & cmd.exe /c ('"{0}"' -f (Join-Path $SourcePath $ScriptFile)) 2>&1 | Out-String
            }
            else {
                throw "Tipo de script nao suportado: $ScriptType"
            }
        }
        finally {
            Pop-Location
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Identity     = Get-ExecutionIdentity
            Script       = $ScriptFile
            Output       = $output.Trim()
        } | ConvertTo-Json -Compress
    }

    'InventoryInstalledSoftware' {
        # Uninstall nativo (64-bit) e WOW6432Node (apps 32-bit em SO 64-bit).
        $paths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )

        $resultados = @(
            Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
                Select-Object DisplayName, DisplayVersion, Publisher, PSPath, UninstallString, QuietUninstallString,
                    @{Name='Escopo'; Expression={'Maquina (HKLM)'}}
        )

        # Instalacoes "so para o usuario atual" (ALLUSERS != 1 no MSI, ou instaladores
        # que escrevem em HKCU) nao aparecem em HKLM. Como este script roda como
        # SYSTEM, o HKCU do processo e o do proprio SYSTEM - por isso e preciso
        # varrer os hives de USUARIO carregados em HKEY_USERS diretamente.
        try {
            if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS -ErrorAction SilentlyContinue | Out-Null
            }

            $userHives = Get-ChildItem -Path 'HKU:\' -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' }

            foreach ($hive in $userHives) {
                $userUninstallPath = "HKU:\$($hive.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
                $resultados += @(
                    Get-ItemProperty -Path $userUninstallPath -ErrorAction SilentlyContinue |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_.DisplayName) } |
                        Select-Object DisplayName, DisplayVersion, Publisher, PSPath, UninstallString, QuietUninstallString,
                            @{Name='Escopo'; Expression={"Usuario ($($hive.PSChildName))"}}
                )
            }
        }
        catch { }

        $resultados | Sort-Object DisplayName | ConvertTo-Json -Compress -Depth 3
    }

    'FindExecutable' {
        if ([string]::IsNullOrWhiteSpace($NamePattern)) { throw 'NamePattern nao informado.' }

        $raizes = New-Object System.Collections.Generic.List[string]
        foreach ($r in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
            if ($r -and (Test-Path -LiteralPath $r)) { $raizes.Add($r) }
        }
        if (-not [string]::IsNullOrWhiteSpace($ExtraRoots)) {
            foreach ($extra in ($ExtraRoots -split ';')) {
                $extraTrim = $extra.Trim()
                if ($extraTrim -and (Test-Path -LiteralPath $extraTrim)) { $raizes.Add($extraTrim) }
            }
        }

        $encontrados = New-Object System.Collections.Generic.List[object]
        foreach ($raiz in ($raizes | Select-Object -Unique)) {
            Get-ChildItem -LiteralPath $raiz -Filter $NamePattern -Recurse -File -Depth 6 -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $versao = $null
                    try { $versao = $_.VersionInfo.FileVersion } catch { }
                    $encontrados.Add([PSCustomObject]@{
                        FullName      = $_.FullName
                        FileVersion   = $versao
                        LastWriteTime = $_.LastWriteTime.ToString('s')
                        LengthKB      = [math]::Round($_.Length / 1KB, 0)
                    })
                }
        }

        ($encontrados | Select-Object -First 200) | ConvertTo-Json -Compress -Depth 3
    }
}
'@
}

function Ensure-CMAppCreatorHelperScript {
    param(
        [string]$ScriptName = 'SCCM-AppCreator-SystemHelper-v3'
    )

    try {
        $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction SilentlyContinue |
            Where-Object { $_.ScriptName -eq $ScriptName } |
            Select-Object -First 1

        if (-not $helper) {
            $helperText = Get-CMAppCreatorHelperScriptText
            New-CMScript -ScriptName $ScriptName -ScriptText $helperText -Fast -ErrorAction Stop | Out-Null
            Start-Sleep -Milliseconds 500
            $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction Stop |
                Where-Object { $_.ScriptName -eq $ScriptName } |
                Select-Object -First 1
        }

        if (-not $helper) {
            throw "Nao foi possivel localizar/criar o helper '$ScriptName'."
        }

        # ApprovalState 3 = Approved. Em ambientes onde o autor nao pode
        # aprovar o proprio script, a tentativa abaixo falha e a GUI explica
        # que a aprovacao precisa ser feita uma unica vez por outro admin.
        if ([int]$helper.ApprovalState -ne 3) {
            try {
                Approve-CMScript -InputObject $helper -Comment 'Helper do SCCM App Creator para testes como SYSTEM.' -Confirm:$false -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 500
                $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction Stop |
                    Where-Object { $_.ScriptName -eq $ScriptName } |
                    Select-Object -First 1
            }
            catch {
                return [PSCustomObject]@{
                    Sucesso = $false
                    Helper  = $helper
                    PrecisaAprovacao = $true
                    Mensagem = "O helper '$ScriptName' foi criado, mas ainda precisa ser APROVADO no SCCM em Software Library > Scripts. Por padrao, o autor nao pode aprovar o proprio script. Depois de aprovado, clique novamente em Conectar via SCCM / SYSTEM."
                }
            }
        }

        if ([int]$helper.ApprovalState -ne 3) {
            return [PSCustomObject]@{
                Sucesso = $false
                Helper  = $helper
                PrecisaAprovacao = $true
                Mensagem = "O helper '$ScriptName' existe, mas ainda nao esta aprovado no SCCM."
            }
        }

        return [PSCustomObject]@{ Sucesso = $true; Helper = $helper; PrecisaAprovacao = $false; Mensagem = "Helper '$ScriptName' aprovado e pronto." }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Helper = $null; PrecisaAprovacao = $false; Mensagem = $_.Exception.Message }
    }
}

function Wait-CMScriptResult {
    param(
        [Parameter(Mandatory)][uint32]$OperationID,
        [Parameter(Mandatory)][string]$SiteServer,
        [Parameter(Mandatory)][string]$SiteCode,
        [int]$TimeoutSeconds = 90,
        [switch]$RequireScriptOutput
    )

    $namespace = "root\SMS\site_$SiteCode"
    $elapsed = 0
    $sawStatus = $false
    $taskId = $null

    do {
        try {
            # 1) A OperationID identifica a execucao enviada pelo Run Script.
            # O payload confiavel nao deve ser assumido diretamente em
            # SMS_ScriptsExecutionStatus. Primeiro resolvemos o TaskID real.
            if (-not $taskId) {
                $execTask = Get-CimInstance -ComputerName $SiteServer -Namespace $namespace -ClassName SMS_ScriptsExecutionTask -ErrorAction SilentlyContinue |
                    Where-Object { [uint32]$_.ClientOperationID -eq [uint32]$OperationID } |
                    Sort-Object ClientOperationID -Descending |
                    Select-Object -First 1
                if ($execTask -and $execTask.TaskID) {
                    $taskId = [string]$execTask.TaskID
                }
            }

            # 2) O status individual continua sendo usado para erro/conectividade.
            $status = Get-CimInstance -ComputerName $SiteServer -Namespace $namespace -ClassName SMS_ScriptsExecutionStatus -Filter "ClientOperationID = '$OperationID'" -ErrorAction SilentlyContinue |
                Sort-Object LastUpdateTime -Descending |
                Select-Object -First 1
        }
        catch {
            throw "Falha consultando o resultado do Run Script no SMS Provider: $($_.Exception.Message)"
        }

        if ($status) {
            $sawStatus = $true
            $scriptError = [string]$status.ScriptError
            if (-not [string]::IsNullOrWhiteSpace($scriptError)) {
                throw "Run Script retornou erro na maquina: $scriptError"
            }

            # Ping: o simples status prova que o cliente respondeu.
            if (-not $RequireScriptOutput) {
                return $status
            }
        }

        if ($RequireScriptOutput -and $taskId) {
            try {
                # 3) O resultado consolidado da execucao fica no Summary.
                # GroupType 1 normalmente representa os resultados retornados
                # pelos clientes. Nao limitamos exclusivamente a ele para manter
                # compatibilidade com builds diferentes do ConfigMgr.
                # TaskID em SMS_ScriptsExecutionTask e SMS_ScriptsExecutionSummary
                # e um GUID/string neste ambiente. Nao converter para UInt32 e nao
                # montar filtro WQL numerico. Consultamos a classe e correlacionamos
                # em memoria pelo TaskID exato.
                $summaries = @(Get-CimInstance -ComputerName $SiteServer -Namespace $namespace -ClassName SMS_ScriptsExecutionSummary -ErrorAction SilentlyContinue |
                    Where-Object { [string]$_.TaskID -eq [string]$taskId })

                $summaryWithOutput = $summaries |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ScriptOutput) } |
                    Sort-Object @{Expression={ if ($_.GroupType -eq 1) { 0 } else { 1 } }} |
                    Select-Object -First 1

                if ($summaryWithOutput) {
                    return [PSCustomObject]@{
                        ClientOperationID = $OperationID
                        TaskID            = $taskId
                        ScriptOutput      = [string]$summaryWithOutput.ScriptOutput
                        ScriptError       = if ($status) { [string]$status.ScriptError } else { '' }
                        LastUpdateTime    = if ($status) { $status.LastUpdateTime } else { $null }
                        ResultSource      = 'SMS_ScriptsExecutionSummary'
                    }
                }
            }
            catch {
                # Continua aguardando: alguns sites demoram alguns segundos para
                # popular o Summary mesmo depois de a execucao ja constar no status.
            }
        }

        Start-Sleep -Seconds 2
        $elapsed += 2
        [System.Windows.Forms.Application]::DoEvents()
    } while ($elapsed -lt $TimeoutSeconds)

    if ($RequireScriptOutput -and $sawStatus) {
        throw "O cliente respondeu ao Run Script, mas o SMS Provider nao disponibilizou o payload em SMS_ScriptsExecutionSummary apos $TimeoutSeconds segundos. OperationID=$OperationID TaskID=$taskId."
    }

    throw "Timeout aguardando retorno da maquina pelo SCCM apos $TimeoutSeconds segundos. Verifique Scripts.log/CcmMessaging.log."
}

function Invoke-CMSystemAction {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('Ping','RunSourceScript','InventoryInstalledSoftware','FindExecutable','RunRegistryDetection','RunFileDetection')][string]$Action,
        [string]$SourcePath,
        [PSCustomObject]$ScriptInfo,
        [string]$NamePattern,
        [string]$ExtraRoots,
        [string]$DisplayNamePattern,
        [string]$MinVersion,
        [string]$FilePath,
        [int]$TimeoutSeconds = 90
    )

    if (-not $script:SiteServer -or -not $script:SiteCode) {
        throw 'Conecte primeiro ao SCCM no grupo 1 da interface.'
    }

    $device = Get-CMDevice -Name $ComputerName -Fast -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $ComputerName } |
        Select-Object -First 1

    if (-not $device) {
        throw "A maquina '$ComputerName' nao foi encontrada como device no SCCM."
    }

    $helperResult = Ensure-CMAppCreatorHelperScript
    if (-not $helperResult.Sucesso) {
        throw $helperResult.Mensagem
    }

    $params = @{ Action = $Action }

    if ($Action -eq 'RunSourceScript') {
        if (-not $ScriptInfo) { throw 'Informacoes do script de install/uninstall nao fornecidas.' }
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'Pasta de origem nao informada.' }
        $params.SourcePath = $SourcePath
        $params.ScriptType = $ScriptInfo.Tipo
        $params.ScriptFile = $ScriptInfo.Arquivo
    }
    elseif ($Action -eq 'FindExecutable') {
        if ([string]::IsNullOrWhiteSpace($NamePattern)) { throw 'Padrao de nome de arquivo nao informado.' }
        $params.NamePattern = $NamePattern
        if (-not [string]::IsNullOrWhiteSpace($ExtraRoots)) { $params.ExtraRoots = $ExtraRoots }
    }
    elseif ($Action -eq 'RunRegistryDetection') {
        if ([string]::IsNullOrWhiteSpace($DisplayNamePattern)) { throw 'Padrao de DisplayName nao informado.' }
        if ([string]::IsNullOrWhiteSpace($MinVersion)) { throw 'Versao minima nao informada.' }
        $params.DisplayNamePattern = $DisplayNamePattern
        $params.MinVersion = $MinVersion
    }
    elseif ($Action -eq 'RunFileDetection') {
        if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'Caminho do arquivo nao informado.' }
        $params.FilePath = $FilePath
        if (-not [string]::IsNullOrWhiteSpace($MinVersion)) { $params.MinVersion = $MinVersion }
    }

    $invoke = Invoke-CMScript -ScriptGuid $helperResult.Helper.ScriptGuid -Device $device -ScriptParameter $params -PassThru -Confirm:$false -ErrorAction Stop
    if (-not $invoke -or -not $invoke.OperationID) {
        throw 'O SCCM nao retornou OperationID para a execucao do Run Script.'
    }

    # Ping e apenas validacao de conectividade logica pelo SCCM: nao exija
    # ScriptOutput. As demais acoes dependem do payload retornado.
    if ($Action -eq 'Ping') {
        return Wait-CMScriptResult -OperationID ([uint32]$invoke.OperationID) -SiteServer $script:SiteServer -SiteCode $script:SiteCode -TimeoutSeconds $TimeoutSeconds
    }

    return Wait-CMScriptResult -OperationID ([uint32]$invoke.OperationID) -SiteServer $script:SiteServer -SiteCode $script:SiteCode -TimeoutSeconds $TimeoutSeconds -RequireScriptOutput
}

function Connect-RemoteTestMachine {
    <#
        Valida a maquina teste pelo proprio SCCM e executa um Ping pelo recurso
        Run Scripts. Nao abre PSSession e nao solicita credenciais da estacao.
    #>
    param([Parameter(Mandatory)][string]$ComputerName)

    try {
        $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action Ping -TimeoutSeconds 60
        $output = $status.ScriptOutput
        $identity = $null
        try {
            $json = $output | ConvertFrom-Json -ErrorAction Stop
            $identity = $json.Identity
        } catch {}

        return [PSCustomObject]@{
            Sucesso  = $true
            Mensagem = if ($identity) { "Maquina respondeu pelo SCCM. Contexto remoto: $identity" } else { "Maquina respondeu ao Run Script do SCCM. Conexao logica validada." }
            Output   = $output
        }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = $_.Exception.Message; Output = $null }
    }
}

function Invoke-RemoteScriptAction {
    <#
        Compatibilidade com os botoes existentes. Agora a execucao remota e
        enviada pelo SCCM e roda no cliente como SYSTEM.

        Observacao: a conta SYSTEM da maquina teste precisa conseguir ler a
        pasta UNC de origem. Caso o share nao permita acesso para a conta do
        computador/Dominio Computers, a GUI exibira o erro devolvido pelo helper.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][PSCustomObject]$ScriptInfo
    )

    $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action RunSourceScript -SourcePath $SourceFolder -ScriptInfo $ScriptInfo -TimeoutSeconds 300
    return $status.ScriptOutput
}

function Invoke-RemoteDetection {
    <#
        Roda a deteccao na maquina teste via SCCM/SYSTEM usando parametros
        curtos (DisplayNamePattern+MinVersion OU FilePath+MinVersion) em vez
        de transportar um script inteiro em Base64 - evita o limite de
        tamanho de parametro do recurso Run Scripts do SCCM.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$DisplayNamePattern,
        [string]$MinVersion,
        [string]$FilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action RunFileDetection -FilePath $FilePath -MinVersion $MinVersion -TimeoutSeconds 90
    }
    else {
        $status = Invoke-CMSystemAction -ComputerName $ComputerName -Action RunRegistryDetection -DisplayNamePattern $DisplayNamePattern -MinVersion $MinVersion -TimeoutSeconds 90
    }
    return $status.ScriptOutput
}

function Get-NormalizedSoftwareName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return (($Name.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

function Resolve-InstalledSoftwareByApplicationName {
    <#
        Localiza automaticamente a melhor entrada do registro usando SOMENTE
        o Nome da Aplicacao informado na interface. Espacos, hifens e outros
        separadores sao ignorados na comparacao (ex.: CapTalk = Cap Talk).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][string]$ApplicationName
    )

    $wanted = Get-NormalizedSoftwareName $ApplicationName
    if ([string]::IsNullOrWhiteSpace($wanted)) { return $null }

    $matches = foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace([string]$item.DisplayName) -or
            [string]::IsNullOrWhiteSpace([string]$item.DisplayVersion)) { continue }

        $actual = Get-NormalizedSoftwareName ([string]$item.DisplayName)
        if ($actual -notlike "*$wanted*" -and $wanted -notlike "*$actual*") { continue }

        $rank = 3
        if ($actual -eq $wanted) { $rank = 0 }
        elseif ($actual.StartsWith($wanted)) { $rank = 1 }
        elseif ($actual.Contains($wanted)) { $rank = 2 }

        [PSCustomObject]@{
            Item = $item
            Rank = $rank
            LengthDelta = [Math]::Abs($actual.Length - $wanted.Length)
        }
    }

    $best = @($matches | Sort-Object Rank, LengthDelta, @{Expression={ $_.Item.DisplayName }})
    if ($best.Count -eq 0) { return $null }
    return $best[0].Item
}

function Show-InstalledSoftwarePicker {
    <#
        Janela modal que lista os programas encontrados no registro da
        maquina teste (via InventoryInstalledSoftware) e deixa o usuario
        filtrar por nome e escolher exatamente qual DisplayName/DisplayVersion
        usar no script de deteccao - reproduzindo a experiencia do "Browse..."
        que o SCCM oferece nativamente para Deployment Types baseados em
        MSI/EXE, mas que nao existe para Script Deployment Types.
    #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$InitialFilter = '',
        [string]$WindowTitle = "Selecione o aplicativo detectado no registro da maquina teste",
        [string[]]$ColumnHeaders = @("Nome (DisplayName)", "Versao", "Fabricante")
    )

    $picker = New-Object System.Windows.Forms.Form
    $picker.Text = $WindowTitle
    $picker.Size = New-Object System.Drawing.Size(660, 460)
    $picker.StartPosition = 'CenterParent'
    $picker.FormBorderStyle = 'FixedDialog'
    $picker.MaximizeBox = $false
    $picker.MinimizeBox = $false

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "Filtrar por nome:"
    $lblFilter.Location = New-Object System.Drawing.Point(10, 12)
    $lblFilter.Size = New-Object System.Drawing.Size(100, 20)
    $picker.Controls.Add($lblFilter)

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Location = New-Object System.Drawing.Point(115, 9)
    $txtFilter.Size = New-Object System.Drawing.Size(520, 20)
    $txtFilter.Text = $InitialFilter
    $picker.Controls.Add($txtFilter)

    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(10, 38)
    $listView.Size = New-Object System.Drawing.Size(625, 330)
    $listView.View = 'Details'
    $listView.FullRowSelect = $true
    $listView.MultiSelect = $false
    $listView.GridLines = $true
    [void]$listView.Columns.Add($ColumnHeaders[0], 320)
    [void]$listView.Columns.Add($ColumnHeaders[1], 110)
    [void]$listView.Columns.Add($ColumnHeaders[2], 175)
    $picker.Controls.Add($listView)

    $script:__pickerItems = $Items

    $refreshList = {
        param($filterText)
        $listView.Items.Clear()
        foreach ($item in $script:__pickerItems) {
            if ([string]::IsNullOrWhiteSpace($filterText) -or $item.DisplayName -like "*$filterText*") {
                $lvi = New-Object System.Windows.Forms.ListViewItem([string]$item.DisplayName)
                [void]$lvi.SubItems.Add([string]$item.DisplayVersion)
                [void]$lvi.SubItems.Add([string]$item.Publisher)
                $lvi.Tag = $item
                [void]$listView.Items.Add($lvi)
            }
        }
    }

    & $refreshList $InitialFilter

    $txtFilter.Add_TextChanged({ & $refreshList $txtFilter.Text }.GetNewClosure())

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(10, 372)
    $lblCount.Size = New-Object System.Drawing.Size(400, 20)
    $lblCount.Text = "$($Items.Count) programa(s) encontrado(s) no total nesta maquina."
    $lblCount.ForeColor = 'Gray'
    $picker.Controls.Add($lblCount)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Selecionar"
    $btnOk.Location = New-Object System.Drawing.Point(455, 368)
    $btnOk.Size = New-Object System.Drawing.Size(90, 28)
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $picker.Controls.Add($btnOk)
    $picker.AcceptButton = $btnOk

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(550, 368)
    $btnCancel.Size = New-Object System.Drawing.Size(85, 28)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $picker.Controls.Add($btnCancel)
    $picker.CancelButton = $btnCancel

    $listView.Add_DoubleClick({
        if ($listView.SelectedItems.Count -gt 0) {
            $picker.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $picker.Close()
        }
    })

    $resultado = $picker.ShowDialog()

    $selecionado = $null
    if ($resultado -eq [System.Windows.Forms.DialogResult]::OK -and $listView.SelectedItems.Count -gt 0) {
        $selecionado = $listView.SelectedItems[0].Tag
    }

    Remove-Variable -Name __pickerItems -Scope script -ErrorAction SilentlyContinue
    return $selecionado
}


function New-SCCMScriptApplication {
    param(
        [Parameter(Mandatory)][string]$AppName,
        [string]$Publisher,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$InstallCommand,
        [Parameter(Mandatory)][string]$UninstallCommand,
        [Parameter(Mandatory)][string]$DetectionScript
    )

    try {
        New-CMApplication -Name $AppName -Publisher $Publisher -SoftwareVersion $Version -ErrorAction Stop | Out-Null

        Add-CMScriptDeploymentType `
            -ApplicationName $AppName `
            -DeploymentTypeName "$AppName - Instalacao via Script" `
            -ContentLocation $SourceFolder `
            -InstallCommand $InstallCommand `
            -UninstallCommand $UninstallCommand `
            -ScriptLanguage 'PowerShell' `
            -ScriptText $DetectionScript `
            -InstallationBehaviorType InstallForSystem `
            -LogonRequirementType WhetherOrNotUserLoggedOn `
            -UserInteractionMode Hidden `
            -ErrorAction Stop | Out-Null

        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Aplicacao '$AppName' criada com sucesso no SCCM." }
    }
    catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------------------
# ESTADO GLOBAL (guarda o que foi escaneado para reaproveitar nos testes/criacao)
# ----------------------------------------------------------------------------
$script:InstallInfo   = $null
$script:UninstallInfo = $null
$script:DetectionText = $null
$script:TestSession   = $null # mantido por compatibilidade; WinRM nao e mais usado
$script:RemoteTestConnected = $false
$script:RemoteTestComputer  = $null
$script:SiteServer          = $null
$script:SiteCode            = $null
$script:SourceCredential  = $null
$script:SourceMappedDrive = $null   # nome do PSDrive temporario, se usado
$script:EffectiveSourcePath = $null # caminho usado de fato para ler arquivos (UNC ou drive mapeado)
$script:OriginalSourcePath  = $null # caminho UNC real, sempre usado no -ContentLocation do SCCM
$script:DetectionMode     = 'Registry'  # 'Registry' ou 'File'
$script:DetectionFilePath = $null       # caminho do executavel, quando DetectionMode = 'File'
$script:DetectedRegistryApp = $null      # entrada real descoberta automaticamente na maquina teste
$script:BuildId = '2026.08.26-REBUILT-STABLE-SOURCEFIX5'

# ----------------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "SCCM App Creator - BUILD $script:BuildId"
$form.Size             = New-Object System.Drawing.Size(720, 905)
$form.StartPosition    = "CenterScreen"
$form.FormBorderStyle  = 'FixedDialog'
$form.MaximizeBox      = $false

# --- Grupo: Conexao SCCM ---
$grpConn = New-Object System.Windows.Forms.GroupBox
$grpConn.Text = "1. Conexao com o SCCM"
$grpConn.Location = New-Object System.Drawing.Point(10, 10)
$grpConn.Size = New-Object System.Drawing.Size(690, 90)
$form.Controls.Add($grpConn)

$lblServer = New-Object System.Windows.Forms.Label
$lblServer.Text = "Site Server:"
$lblServer.Location = New-Object System.Drawing.Point(10, 25)
$lblServer.Size = New-Object System.Drawing.Size(80, 20)
$grpConn.Controls.Add($lblServer)

$txtServer = New-Object System.Windows.Forms.TextBox
$txtServer.Location = New-Object System.Drawing.Point(95, 22)
$txtServer.Size = New-Object System.Drawing.Size(220, 20)
$grpConn.Controls.Add($txtServer)

$lblSiteCode = New-Object System.Windows.Forms.Label
$lblSiteCode.Text = "Site Code:"
$lblSiteCode.Location = New-Object System.Drawing.Point(330, 25)
$lblSiteCode.Size = New-Object System.Drawing.Size(70, 20)
$grpConn.Controls.Add($lblSiteCode)

$txtSiteCode = New-Object System.Windows.Forms.TextBox
$txtSiteCode.Location = New-Object System.Drawing.Point(405, 22)
$txtSiteCode.Size = New-Object System.Drawing.Size(80, 20)
$grpConn.Controls.Add($txtSiteCode)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "Conectar"
$btnConnect.Location = New-Object System.Drawing.Point(500, 20)
$btnConnect.Size = New-Object System.Drawing.Size(90, 25)
$grpConn.Controls.Add($btnConnect)

$lblConnStatus = New-Object System.Windows.Forms.Label
$lblConnStatus.Text = "Nao conectado."
$lblConnStatus.ForeColor = 'Red'
$lblConnStatus.Location = New-Object System.Drawing.Point(10, 55)
$lblConnStatus.Size = New-Object System.Drawing.Size(650, 20)
$grpConn.Controls.Add($lblConnStatus)

# --- Grupo: Dados da Aplicacao ---
$grpApp = New-Object System.Windows.Forms.GroupBox
$grpApp.Text = "2. Dados da Aplicacao"
$grpApp.Location = New-Object System.Drawing.Point(10, 110)
$grpApp.Size = New-Object System.Drawing.Size(690, 240)
$form.Controls.Add($grpApp)

$lblAppName = New-Object System.Windows.Forms.Label
$lblAppName.Text = "Nome da Aplicacao:"
$lblAppName.Location = New-Object System.Drawing.Point(10, 25)
$lblAppName.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblAppName)

$txtAppName = New-Object System.Windows.Forms.TextBox
$txtAppName.Location = New-Object System.Drawing.Point(140, 22)
$txtAppName.Size = New-Object System.Drawing.Size(350, 20)
$grpApp.Controls.Add($txtAppName)

$txtAppName.Add_TextChanged({
    if ($script:DetectedRegistryApp) {
        $script:DetectedRegistryApp = $null
        $script:DetectionText = $null
        $txtVersion.Text = ''
        $txtDetectPattern.Text = ''
        if ($lblDetectionMode) {
            $lblDetectionMode.Text = 'Deteccao ainda nao gerada para este nome.'
            $lblDetectionMode.ForeColor = 'Gray'
        }
    }
})

$txtAppName.Add_TextChanged({
    if ($script:DetectionMode -eq 'Registry') {
        $script:DetectedRegistryApp = $null
        $script:DetectionText = $null
        $txtDetectPattern.Text = ''
        $txtVersion.Text = ''
        $lblDetectionMode.Text = "Modo de deteccao: aguardando descoberta pelo Nome da Aplicacao."
        $lblDetectionMode.ForeColor = 'Gray'
    }
})

$lblPublisher = New-Object System.Windows.Forms.Label
$lblPublisher.Text = "Fabricante:"
$lblPublisher.Location = New-Object System.Drawing.Point(10, 55)
$lblPublisher.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblPublisher)

$txtPublisher = New-Object System.Windows.Forms.TextBox
$txtPublisher.Location = New-Object System.Drawing.Point(140, 52)
$txtPublisher.Size = New-Object System.Drawing.Size(350, 20)
$grpApp.Controls.Add($txtPublisher)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "Versao detectada:"
$lblVersion.Location = New-Object System.Drawing.Point(10, 85)
$lblVersion.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblVersion)

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Location = New-Object System.Drawing.Point(140, 82)
$txtVersion.Size = New-Object System.Drawing.Size(150, 20)
$grpApp.Controls.Add($txtVersion)

$lblDetectPattern = New-Object System.Windows.Forms.Label
$lblDetectPattern.Text = "DisplayName detectado:"
$lblDetectPattern.Location = New-Object System.Drawing.Point(300, 85)
$lblDetectPattern.Size = New-Object System.Drawing.Size(190, 20)
$grpApp.Controls.Add($lblDetectPattern)

$txtDetectPattern = New-Object System.Windows.Forms.TextBox
$txtDetectPattern.Location = New-Object System.Drawing.Point(495, 82)
$txtDetectPattern.Size = New-Object System.Drawing.Size(190, 20)
$grpApp.Controls.Add($txtDetectPattern)

$lblSourceFolder = New-Object System.Windows.Forms.Label
$lblSourceFolder.Text = "Pasta de Origem (source):"
$lblSourceFolder.Location = New-Object System.Drawing.Point(10, 115)
$lblSourceFolder.Size = New-Object System.Drawing.Size(150, 20)
$grpApp.Controls.Add($lblSourceFolder)

$txtSourceFolder = New-Object System.Windows.Forms.TextBox
$txtSourceFolder.Location = New-Object System.Drawing.Point(140, 112)
$txtSourceFolder.Size = New-Object System.Drawing.Size(540, 20)
$txtSourceFolder.ShortcutsEnabled = $true
$grpApp.Controls.Add($txtSourceFolder)

# Se o operador alterar o campo depois do scan, invalida o estado anterior.
$txtSourceFolder.Add_TextChanged({
    $current = Get-CleanPath -Path $txtSourceFolder.Text
    if ($script:OriginalSourcePath -and $current -ne $script:OriginalSourcePath) {
        $script:OriginalSourcePath = $null
        $script:EffectiveSourcePath = $null
        $script:InstallInfo = $null
        $script:UninstallInfo = $null
        $txtInstallCmd.Text = ''
        $txtUninstallCmd.Text = ''
        $lblScanResult.Text = 'Pasta alterada - escaneie novamente.'
    }
})


$btnPasteFolder = New-Object System.Windows.Forms.Button
$btnPasteFolder.Text = "Colar"
$btnPasteFolder.Location = New-Object System.Drawing.Point(140, 138)
$btnPasteFolder.Size = New-Object System.Drawing.Size(60, 23)
$grpApp.Controls.Add($btnPasteFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Procurar..."
$btnBrowse.Location = New-Object System.Drawing.Point(205, 138)
$btnBrowse.Size = New-Object System.Drawing.Size(80, 23)
$grpApp.Controls.Add($btnBrowse)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = "Escanear Pasta"
$btnScan.Location = New-Object System.Drawing.Point(290, 138)
$btnScan.Size = New-Object System.Drawing.Size(120, 23)
$grpApp.Controls.Add($btnScan)

$btnUseInteractiveSession = New-Object System.Windows.Forms.Button
$btnUseInteractiveSession.Text = "Usar sessao logada (sem senha)"
$btnUseInteractiveSession.Location = New-Object System.Drawing.Point(140, 165)
$btnUseInteractiveSession.Size = New-Object System.Drawing.Size(220, 23)
$grpApp.Controls.Add($btnUseInteractiveSession)

$btnSourceCred = New-Object System.Windows.Forms.Button
$btnSourceCred.Text = "Ou informar credencial..."
$btnSourceCred.Location = New-Object System.Drawing.Point(365, 165)
$btnSourceCred.Size = New-Object System.Drawing.Size(150, 23)
$grpApp.Controls.Add($btnSourceCred)

$btnClearSourceCred = New-Object System.Windows.Forms.Button
$btnClearSourceCred.Text = "Limpar"
$btnClearSourceCred.Location = New-Object System.Drawing.Point(520, 165)
$btnClearSourceCred.Size = New-Object System.Drawing.Size(55, 23)
$grpApp.Controls.Add($btnClearSourceCred)

$lblSourceCredStatus = New-Object System.Windows.Forms.Label
$lblSourceCredStatus.Text = "Acesso a pasta: usando a conta atual do script."
$lblSourceCredStatus.ForeColor = 'Gray'
$lblSourceCredStatus.Location = New-Object System.Drawing.Point(10, 192)
$lblSourceCredStatus.Size = New-Object System.Drawing.Size(670, 18)
$grpApp.Controls.Add($lblSourceCredStatus)

$lblScanResult = New-Object System.Windows.Forms.Label
$lblScanResult.Text = "Instalacao: -- | Desinstalacao: --"
$lblScanResult.Location = New-Object System.Drawing.Point(10, 210)
$lblScanResult.Size = New-Object System.Drawing.Size(670, 20)
$grpApp.Controls.Add($lblScanResult)

# --- Grupo: Maquina de Teste Remota (CyberArk / conta de servico sem acesso a maquina teste) ---
$grpRemote = New-Object System.Windows.Forms.GroupBox
$grpRemote.Text = "3. Maquina de Teste (Remota - opcional, use quando o script roda no servidor)"
$grpRemote.Location = New-Object System.Drawing.Point(10, 360)
$grpRemote.Size = New-Object System.Drawing.Size(690, 125)
$form.Controls.Add($grpRemote)

$lblTestMachine = New-Object System.Windows.Forms.Label
$lblTestMachine.Text = "Nome/IP da maquina teste:"
$lblTestMachine.Location = New-Object System.Drawing.Point(10, 25)
$lblTestMachine.Size = New-Object System.Drawing.Size(150, 20)
$grpRemote.Controls.Add($lblTestMachine)

$txtTestMachine = New-Object System.Windows.Forms.TextBox
$txtTestMachine.Location = New-Object System.Drawing.Point(165, 22)
$txtTestMachine.Size = New-Object System.Drawing.Size(200, 20)
$grpRemote.Controls.Add($txtTestMachine)

$btnConnectRemote = New-Object System.Windows.Forms.Button
$btnConnectRemote.Text = "Conectar via SCCM / SYSTEM"
$btnConnectRemote.Location = New-Object System.Drawing.Point(375, 21)
$btnConnectRemote.Size = New-Object System.Drawing.Size(170, 23)
$grpRemote.Controls.Add($btnConnectRemote)

$btnDisconnectRemote = New-Object System.Windows.Forms.Button
$btnDisconnectRemote.Text = "Desconectar"
$btnDisconnectRemote.Location = New-Object System.Drawing.Point(555, 21)
$btnDisconnectRemote.Size = New-Object System.Drawing.Size(125, 23)
$grpRemote.Controls.Add($btnDisconnectRemote)

$lblRemoteStatus = New-Object System.Windows.Forms.Label
$lblRemoteStatus.Text = "Sem maquina teste conectada pelo SCCM (testes rodarao localmente)."
$lblRemoteStatus.ForeColor = 'Gray'
$lblRemoteStatus.Location = New-Object System.Drawing.Point(10, 48)
$lblRemoteStatus.Size = New-Object System.Drawing.Size(670, 18)
$grpRemote.Controls.Add($lblRemoteStatus)

$btnDetectRegistry = New-Object System.Windows.Forms.Button
$btnDetectRegistry.Text = "Gerar Deteccao pelo Nome da Aplicacao"
$btnDetectRegistry.Location = New-Object System.Drawing.Point(10, 70)
$btnDetectRegistry.Size = New-Object System.Drawing.Size(280, 25)
$btnDetectRegistry.BackColor = [System.Drawing.Color]::LightSteelBlue
$grpRemote.Controls.Add($btnDetectRegistry)

$btnDetectFile = New-Object System.Windows.Forms.Button
$btnDetectFile.Text = "Detectar por Arquivo/Executavel..."
$btnDetectFile.Location = New-Object System.Drawing.Point(300, 70)
$btnDetectFile.Size = New-Object System.Drawing.Size(230, 25)
$btnDetectFile.BackColor = [System.Drawing.Color]::LightGoldenrodYellow
$grpRemote.Controls.Add($btnDetectFile)

$btnClearFileDetection = New-Object System.Windows.Forms.Button
$btnClearFileDetection.Text = "Voltar p/ Registro Automatico"
$btnClearFileDetection.Location = New-Object System.Drawing.Point(540, 70)
$btnClearFileDetection.Size = New-Object System.Drawing.Size(140, 25)
$grpRemote.Controls.Add($btnClearFileDetection)

$lblDetectionMode = New-Object System.Windows.Forms.Label
$lblDetectionMode.Text = "Modo de deteccao: Registro automatico pelo Nome da Aplicacao."
$lblDetectionMode.ForeColor = 'Gray'
$lblDetectionMode.Location = New-Object System.Drawing.Point(10, 98)
$lblDetectionMode.Size = New-Object System.Drawing.Size(670, 18)
$grpRemote.Controls.Add($lblDetectionMode)

# --- Grupo: Comandos gerados ---
$grpCmds = New-Object System.Windows.Forms.GroupBox
$grpCmds.Text = "4. Linhas geradas (SCCM Deployment Type)"
$grpCmds.Location = New-Object System.Drawing.Point(10, 495)
$grpCmds.Size = New-Object System.Drawing.Size(690, 130)
$form.Controls.Add($grpCmds)

$lblInstallCmd = New-Object System.Windows.Forms.Label
$lblInstallCmd.Text = "Install command:"
$lblInstallCmd.Location = New-Object System.Drawing.Point(10, 22)
$lblInstallCmd.Size = New-Object System.Drawing.Size(100, 20)
$grpCmds.Controls.Add($lblInstallCmd)

$txtInstallCmd = New-Object System.Windows.Forms.TextBox
$txtInstallCmd.Location = New-Object System.Drawing.Point(10, 42)
$txtInstallCmd.Size = New-Object System.Drawing.Size(670, 20)
$txtInstallCmd.ReadOnly = $true
$grpCmds.Controls.Add($txtInstallCmd)

$lblUninstallCmd = New-Object System.Windows.Forms.Label
$lblUninstallCmd.Text = "Uninstall command:"
$lblUninstallCmd.Location = New-Object System.Drawing.Point(10, 68)
$lblUninstallCmd.Size = New-Object System.Drawing.Size(120, 20)
$grpCmds.Controls.Add($lblUninstallCmd)

$txtUninstallCmd = New-Object System.Windows.Forms.TextBox
$txtUninstallCmd.Location = New-Object System.Drawing.Point(10, 88)
$txtUninstallCmd.Size = New-Object System.Drawing.Size(670, 20)
$txtUninstallCmd.ReadOnly = $true
$grpCmds.Controls.Add($txtUninstallCmd)

# --- Grupo: Testes (local ou remoto, dependendo da sessao) ---
$grpTest = New-Object System.Windows.Forms.GroupBox
$grpTest.Text = "5. Testes (local por padrao, ou na maquina remota se conectada acima)"
$grpTest.Location = New-Object System.Drawing.Point(10, 635)
$grpTest.Size = New-Object System.Drawing.Size(690, 60)
$form.Controls.Add($grpTest)

$btnTestInstall = New-Object System.Windows.Forms.Button
$btnTestInstall.Text = "Testar Instalacao"
$btnTestInstall.Location = New-Object System.Drawing.Point(10, 22)
$btnTestInstall.Size = New-Object System.Drawing.Size(140, 25)
$grpTest.Controls.Add($btnTestInstall)

$btnTestUninstall = New-Object System.Windows.Forms.Button
$btnTestUninstall.Text = "Testar Desinstalacao"
$btnTestUninstall.Location = New-Object System.Drawing.Point(160, 22)
$btnTestUninstall.Size = New-Object System.Drawing.Size(140, 25)
$grpTest.Controls.Add($btnTestUninstall)

$btnTestDetection = New-Object System.Windows.Forms.Button
$btnTestDetection.Text = "Testar Deteccao"
$btnTestDetection.Location = New-Object System.Drawing.Point(310, 22)
$btnTestDetection.Size = New-Object System.Drawing.Size(140, 25)
$grpTest.Controls.Add($btnTestDetection)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = "Criar Aplicacao no SCCM"
$btnCreate.Location = New-Object System.Drawing.Point(470, 20)
$btnCreate.Size = New-Object System.Drawing.Size(210, 30)
$btnCreate.BackColor = [System.Drawing.Color]::LightGreen
$grpTest.Controls.Add($btnCreate)

# --- Log ---
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(10, 705)
$txtLog.Size = New-Object System.Drawing.Size(690, 160)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8)
$form.Controls.Add($txtLog)

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Message`r`n")
}

# ----------------------------------------------------------------------------
# EVENTOS
# ----------------------------------------------------------------------------

$btnConnect.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtServer.Text) -or [string]::IsNullOrWhiteSpace($txtSiteCode.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o Site Server e o Site Code.", "Aviso") | Out-Null
        return
    }
    Write-Log "Conectando a $($txtServer.Text) ($($txtSiteCode.Text))..."
    $result = Connect-ToSCCM -SiteServer $txtServer.Text -SiteCode $txtSiteCode.Text
    if ($result.Sucesso) {
        $script:SiteServer = $txtServer.Text.Trim()
        $script:SiteCode   = $txtSiteCode.Text.Trim()
        $lblConnStatus.Text = $result.Mensagem
        $lblConnStatus.ForeColor = 'Green'
    } else {
        $lblConnStatus.Text = "Falha: $($result.Mensagem)"
        $lblConnStatus.ForeColor = 'Red'
    }
    Write-Log $result.Mensagem
})

$btnPasteFolder.Add_Click({
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $textoOriginal = [System.Windows.Forms.Clipboard]::GetText()
            $textoLimpo = Get-CleanPath -Path $textoOriginal
            $txtSourceFolder.Text = $textoLimpo
            if ($textoOriginal.Trim() -ne $textoLimpo) {
                Write-Log "Caminho colado foi limpo automaticamente (aspas/espacos removidos)."
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("A area de transferencia nao contem texto.", "Aviso") | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Nao foi possivel ler a area de transferencia. Isso costuma acontecer quando o script esta rodando como Administrador " +
            "e o texto foi copiado por um programa sem elevacao (bloqueio de UIPI do Windows).`n`n" +
            "Solucao: rode o script SEM 'Executar como Administrador' (a conexao ao SCCM nao exige elevacao), " +
            "ou digite o caminho manualmente no campo.",
            "Erro ao colar",
            'OK', 'Warning'
        ) | Out-Null
    }
})

$btnBrowse.Add_Click({
    # FolderBrowserDialog classico nao permite digitar/colar caminhos UNC (\\servidor\pasta).
    # Truque: usar OpenFileDialog (que tem barra de endereco completa e aceita UNC) para
    # navegar/digitar ate a pasta desejada e depois pegar so o diretorio.
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Navegue ate a pasta de origem (ou cole/digite o caminho UNC na barra 'Nome do arquivo') e clique Abrir"
    $dlg.CheckFileExists = $false
    $dlg.CheckPathExists = $true
    $dlg.ValidateNames = $false
    $dlg.Multiselect = $false
    $dlg.FileName = "Selecione esta pasta"
    $dlg.Filter = "Pastas|*.pasta"

    if ($dlg.ShowDialog() -eq 'OK') {
        $pasta = Split-Path $dlg.FileName -Parent
        $txtSourceFolder.Text = $pasta
    }
})

function Complete-FolderScan {
    <# Guarda SEMPRE o UNC original. O caminho de leitura e apenas operacional. #>
    param(
        [Parameter(Mandatory)][string]$CaminhoOriginal,
        [PSCustomObject]$Acesso,
        [PSCustomObject]$Manifest
    )

    $cleanOriginal = Get-CleanPath -Path $CaminhoOriginal
    $script:OriginalSourcePath = $cleanOriginal

    if ($Manifest) {
        $script:EffectiveSourcePath = $null
        $script:InstallInfo = $Manifest.InstallInfo
        $script:UninstallInfo = $Manifest.UninstallInfo
        Write-Log $Manifest.Mensagem
    }
    elseif ($Acesso -and $Acesso.Sucesso) {
        $script:EffectiveSourcePath = $Acesso.CaminhoEfetivo
        Write-Log $Acesso.Mensagem
        $script:InstallInfo = Get-InstallCommandLine -FolderPath $script:EffectiveSourcePath -Action 'install'
        $script:UninstallInfo = Get-InstallCommandLine -FolderPath $script:EffectiveSourcePath -Action 'uninstall'
    }
    else {
        throw 'Complete-FolderScan recebeu um estado de acesso invalido.'
    }

    $installStatus = if ($script:InstallInfo.Encontrado) { "$($script:InstallInfo.Tipo) ($($script:InstallInfo.Arquivo))" } else { 'NAO ENCONTRADO' }
    $uninstallStatus = if ($script:UninstallInfo.Encontrado) { "$($script:UninstallInfo.Tipo) ($($script:UninstallInfo.Arquivo))" } else { 'NAO ENCONTRADO' }
    $lblScanResult.Text = "Instalacao: $installStatus | Desinstalacao: $uninstallStatus"
    $txtInstallCmd.Text = if ($script:InstallInfo.Encontrado) { $script:InstallInfo.Comando } else { '' }
    $txtUninstallCmd.Text = if ($script:UninstallInfo.Encontrado) { $script:UninstallInfo.Comando } else { '' }

    Write-Log "SOURCE ORIGINAL FIXADO: $($script:OriginalSourcePath)"
    if ($script:InstallInfo.Encontrado -and $script:UninstallInfo.Encontrado) {
        Write-Log "Scripts encontrados. Install: $($script:InstallInfo.Comando) | Uninstall: $($script:UninstallInfo.Comando)"
    } else {
        Write-Log 'ATENCAO: install/uninstall nao foram ambos encontrados na raiz da pasta de origem.'
    }
}


$btnUseInteractiveSession.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Informe a pasta de origem primeiro.', 'Aviso') | Out-Null
        return
    }

    $caminhoLimpo = Get-CleanPath -Path $txtSourceFolder.Text
    $txtSourceFolder.Text = $caminhoLimpo
    Write-Log "Lendo a pasta pela sessao Windows logada, sem copiar o pacote: $caminhoLimpo"
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $manifest = Get-SourceManifestViaInteractiveSession -SourcePath $caminhoLimpo }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }

    if (-not $manifest.Sucesso) {
        Write-Log "Falha ao ler pasta via sessao interativa: $($manifest.Mensagem)"
        [System.Windows.Forms.MessageBox]::Show($manifest.Mensagem, 'Falha ao ler pasta', 'OK', 'Warning') | Out-Null
        return
    }

    $lblSourceCredStatus.Text = 'Acesso a pasta: leitura pela sessao Windows logada (sem copia).'
    $lblSourceCredStatus.ForeColor = 'Green'
    Complete-FolderScan -CaminhoOriginal $caminhoLimpo -Manifest $manifest
})


$btnSourceCred.Add_Click({
    $cred = Get-Credential -Message "Credenciais com acesso de LEITURA a pasta de origem (ex: sua conta pessoal, se a conta que roda este script - ex: conta de servico do SCCM - nao tiver acesso ao share)"
    if (-not $cred) { return }
    $script:SourceCredential = $cred
    $lblSourceCredStatus.Text = "Acesso a pasta: usando credencial informada ($($cred.UserName))."
    $lblSourceCredStatus.ForeColor = 'Green'
    Write-Log "Credencial alternativa definida para acesso a pasta de origem ($($cred.UserName))."
})

$btnClearSourceCred.Add_Click({
    $script:SourceCredential = $null
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }
    $lblSourceCredStatus.Text = "Acesso a pasta: usando a conta atual do script."
    $lblSourceCredStatus.ForeColor = 'Gray'
    Write-Log "Credencial alternativa removida. Voltando a usar a conta atual do script."
})

$btnScan.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe a pasta de origem.", "Aviso") | Out-Null
        return
    }

    # Sempre normaliza o texto do campo antes de validar (remove aspas/espacos
    # que podem ter vindo de copia da barra de enderecos do Explorer).
    $caminhoOriginal = $txtSourceFolder.Text
    $caminhoLimpo    = Get-CleanPath -Path $caminhoOriginal
    if ($caminhoOriginal -ne $caminhoLimpo) {
        $txtSourceFolder.Text = $caminhoLimpo
        Write-Log "Caminho normalizado antes de validar: '$caminhoLimpo'"
    }

    if ($script:SourceCredential) {
        Write-Log "Testando acesso a pasta com a credencial alternativa ($($script:SourceCredential.UserName))..."
    } else {
        Write-Log "Testando acesso a pasta com a conta atual do script..."
    }

    $acesso = Resolve-SourceAccess -Path $caminhoLimpo -Credential $script:SourceCredential

    if (-not $acesso.Sucesso) {
        Write-Log "Falha ao acessar a pasta: $($acesso.Mensagem)"
        Write-Log "Caminho testado: [`"$caminhoLimpo`"] (tamanho: $($caminhoLimpo.Length) caracteres)"
        [System.Windows.Forms.MessageBox]::Show(
            "Nao foi possivel acessar este caminho:`n`n$caminhoLimpo`n`n" +
            "Detalhe: $($acesso.Mensagem)`n`n" +
            "Se voce nao tem uma credencial para digitar, use o botao " +
            "'Usar sessao logada (sem senha)' em vez deste.",
            "Nao foi possivel acessar a pasta",
            'OK', 'Warning'
        ) | Out-Null
        return
    }

    Complete-FolderScan -CaminhoOriginal $caminhoLimpo -Acesso $acesso
})

$btnConnectRemote.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtTestMachine.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o nome da maquina teste.", "Aviso") | Out-Null
        return
    }
    if (-not $script:SiteServer -or -not $script:SiteCode) {
        [System.Windows.Forms.MessageBox]::Show("Conecte primeiro ao SCCM no grupo 1.", "Aviso") | Out-Null
        return
    }

    $computer = $txtTestMachine.Text.Trim()
    $btnConnectRemote.Enabled = $false
    $lblRemoteStatus.Text = "Validando $computer pelo SCCM..."
    $lblRemoteStatus.ForeColor = 'DarkOrange'
    [System.Windows.Forms.Application]::DoEvents()

    Write-Log "Validando maquina teste $computer via SCCM Run Script (sem WinRM/sem credencial da estacao)..."
    $result = Connect-RemoteTestMachine -ComputerName $computer

    if ($result.Sucesso) {
        $script:RemoteTestConnected = $true
        $script:RemoteTestComputer  = $computer
        $lblRemoteStatus.Text = "Conectado via SCCM: $computer - execucao remota como SYSTEM."
        $lblRemoteStatus.ForeColor = 'Green'
    }
    else {
        $script:RemoteTestConnected = $false
        $script:RemoteTestComputer  = $null
        $lblRemoteStatus.Text = "Falha via SCCM: $($result.Mensagem)"
        $lblRemoteStatus.ForeColor = 'Red'

        if ($result.Mensagem -match 'APROV') {
            [System.Windows.Forms.MessageBox]::Show(
                $result.Mensagem,
                "Aprovacao unica necessaria",
                'OK', 'Information'
            ) | Out-Null
        }
    }

    Write-Log $result.Mensagem
    $btnConnectRemote.Enabled = $true
})

$btnDisconnectRemote.Add_Click({
    $script:RemoteTestConnected = $false
    $script:RemoteTestComputer  = $null
    $lblRemoteStatus.Text = "Sem maquina teste conectada pelo SCCM (testes rodarao localmente)."
    $lblRemoteStatus.ForeColor = 'Gray'
    Write-Log "Maquina teste desconectada da sessao logica do App Creator. Nenhuma PSSession/WinRM foi usada."
})

$btnDetectRegistry.Add_Click({
    if (-not $script:RemoteTestConnected -or -not $script:RemoteTestComputer) {
        [System.Windows.Forms.MessageBox]::Show("Conecte primeiro na maquina teste (botao 'Conectar via SCCM / SYSTEM' acima).", "Aviso") | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtAppName.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Informe somente o Nome da Aplicacao. A versao sera descoberta automaticamente no registro da maquina teste.", "Aviso") | Out-Null
        return
    }

    $appSearchName = $txtAppName.Text.Trim()
    Write-Log "[AUTO] Procurando '$appSearchName' no registro de $($script:RemoteTestComputer) via SCCM/SYSTEM. A versao digitada na interface NAO participa desta busca."
    $btnDetectRegistry.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $status = $null
    $erro = $null
    try {
        $status = Invoke-CMSystemAction -ComputerName $script:RemoteTestComputer -Action InventoryInstalledSoftware -TimeoutSeconds 120
    }
    catch { $erro = $_.Exception.Message }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnDetectRegistry.Enabled = $true
    }

    if ($erro) {
        Write-Log "Erro ao consultar registro remoto: $erro"
        [System.Windows.Forms.MessageBox]::Show($erro, "Erro ao consultar registro", 'OK', 'Error') | Out-Null
        return
    }

    $raw = [string]$status.ScriptOutput
    Write-Log "[AUTO] Run Script concluido. Tamanho do ScriptOutput: $($raw.Length) caractere(s)."
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "A execucao terminou sem ScriptOutput utilizavel (isso nao deve mais ocorrer apos o novo sincronismo)."
        [System.Windows.Forms.MessageBox]::Show("A maquina teste nao retornou nenhum dado. Verifique se o cliente SCCM esta online.", "Aviso") | Out-Null
        return
    }

    try { $json = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-Log "Falha ao interpretar o retorno JSON do inventario: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("A resposta da maquina teste nao pode ser lida como JSON.`n`nRetorno bruto:`n$raw", "Erro ao interpretar resposta", 'OK', 'Error') | Out-Null
        return
    }
    if ($json -isnot [System.Array]) { $json = @($json) }

    $selecionado = Resolve-InstalledSoftwareByApplicationName -Items @($json) -ApplicationName $appSearchName
    if (-not $selecionado) {
        $script:DetectedRegistryApp = $null
        Write-Log "[AUTO] Nenhuma entrada com DisplayVersion encontrada para '$appSearchName'."
        [System.Windows.Forms.MessageBox]::Show(
            "Nao encontrei '$appSearchName' no registro da maquina teste.`n`nA busca ignorou espacos/hifens e verificou HKLM 64-bit, WOW6432Node e perfis de usuario carregados.",
            "Aplicacao nao encontrada", 'OK', 'Warning') | Out-Null
        return
    }

    $script:DetectedRegistryApp = $selecionado
    $txtDetectPattern.Text = [string]$selecionado.DisplayName
    $txtVersion.Text = [string]$selecionado.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($txtPublisher.Text) -and -not [string]::IsNullOrWhiteSpace([string]$selecionado.Publisher)) {
        $txtPublisher.Text = [string]$selecionado.Publisher
    }

    $script:DetectionMode = 'Registry'
    $script:DetectionFilePath = $null
    $lblDetectionMode.Text = "Registro AUTO: $($selecionado.DisplayName) >= $($selecionado.DisplayVersion)"
    $lblDetectionMode.ForeColor = 'DarkGreen'

    $script:DetectionText = New-DetectionScriptText -DisplayNamePattern ([string]$selecionado.DisplayName) -MinVersion ([string]$selecionado.DisplayVersion)

    Write-Log "[AUTO] ENCONTRADO: DisplayName='$($selecionado.DisplayName)' | DisplayVersion='$($selecionado.DisplayVersion)' | Publisher='$($selecionado.Publisher)' | Escopo='$($selecionado.Escopo)'"
    Write-Log "[AUTO] Script de Detection Method gerado usando a versao REAL encontrada no registro: $($selecionado.DisplayVersion)."

    [System.Windows.Forms.MessageBox]::Show(
        "Deteccao gerada automaticamente.`n`n" +
        "Nome informado: $appSearchName`n" +
        "DisplayName real: $($selecionado.DisplayName)`n" +
        "Versao encontrada: $($selecionado.DisplayVersion)`n" +
        "Escopo: $($selecionado.Escopo)`n`n" +
        "A versao foi lida do registro da maquina teste; ela NAO foi usada para localizar a aplicacao.",
        "Deteccao automatica concluida", 'OK', 'Information') | Out-Null
})

$btnDetectFile.Add_Click({
    if (-not $script:RemoteTestConnected -or -not $script:RemoteTestComputer) {
        [System.Windows.Forms.MessageBox]::Show("Conecte primeiro na maquina teste (botao 'Conectar via SCCM / SYSTEM' acima).", "Aviso") | Out-Null
        return
    }

    $sugestaoNome = if (-not [string]::IsNullOrWhiteSpace($txtAppName.Text)) {
        "*" + ($txtAppName.Text -replace '\s', '') + "*.exe"
    } else { "*.exe" }

    $pattern = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Padrao do nome do arquivo executavel a procurar (aceita curinga *).`n`n" +
        "A busca padrao cobre: Program Files, Program Files (x86) e ProgramData.`n" +
        "Use isso quando o app NAO aparecer no registro (Detectar no Registro) nem nas " +
        "pastas padrao - por exemplo instaladores que nao registram nada no Windows.",
        "Buscar executavel na maquina teste",
        $sugestaoNome
    )
    if ([string]::IsNullOrWhiteSpace($pattern)) { return }

    $extraRoots = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Pastas adicionais para procurar tambem (opcional), separadas por ponto-e-virgula.`n" +
        "Exemplo: D:\Apps;C:\CapTalk`n`n" +
        "Deixe em branco para procurar so nas pastas padrao.",
        "Pastas adicionais (opcional)",
        ""
    )

    Write-Log "Procurando '$pattern' em $($script:RemoteTestComputer) (Program Files, Program Files (x86), ProgramData$(if ($extraRoots) { ' + pastas extras: ' + $extraRoots }))... isso pode demorar ate alguns minutos."
    $btnDetectFile.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $status = $null
    $erro = $null
    try {
        $status = Invoke-CMSystemAction -ComputerName $script:RemoteTestComputer -Action FindExecutable -NamePattern $pattern -ExtraRoots $extraRoots -TimeoutSeconds 240
    }
    catch {
        $erro = $_.Exception.Message
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnDetectFile.Enabled = $true
    }

    if ($erro) {
        Write-Log "Erro na busca por arquivo: $erro"
        [System.Windows.Forms.MessageBox]::Show($erro, "Erro na busca por arquivo", 'OK', 'Error') | Out-Null
        return
    }

    $raw = $status.ScriptOutput
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "Nenhum arquivo encontrado com o padrao '$pattern' nas pastas pesquisadas."
        [System.Windows.Forms.MessageBox]::Show(
            "Nenhum arquivo encontrado com o padrao '$pattern' em Program Files / Program Files (x86) / ProgramData" +
            $(if ($extraRoots) { " nem em: $extraRoots" } else { "" }) + ".`n`n" +
            "Tente um padrao mais amplo (ex: '*.exe' sem prefixo) ou informe uma pasta adicional onde o app foi instalado.",
            "Nenhum resultado",
            'OK', 'Warning'
        ) | Out-Null
        return
    }

    try {
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Falha ao interpretar retorno da busca por arquivo: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Resposta invalida da maquina teste.`n`n$raw", "Erro", 'OK', 'Error') | Out-Null
        return
    }

    if ($json -isnot [System.Array]) { $json = @($json) }

    if ($json.Count -eq 0) {
        Write-Log "Nenhum arquivo encontrado com o padrao '$pattern'."
        [System.Windows.Forms.MessageBox]::Show("Nenhum arquivo encontrado com o padrao '$pattern'.", "Aviso") | Out-Null
        return
    }

    Write-Log "Encontrados $($json.Count) arquivo(s) com o padrao '$pattern'. Abrindo lista para selecao..."

    # Reaproveita o mesmo picker usado para o registro, mapeando FullName/FileVersion/LastWriteTime
    # nas mesmas 3 colunas (com titulos customizados para fazer sentido nesse contexto).
    $itemsParaPicker = $json | ForEach-Object {
        [PSCustomObject]@{
            DisplayName    = $_.FullName
            DisplayVersion = $_.FileVersion
            Publisher      = $_.LastWriteTime
        }
    }

    $selecionado = Show-InstalledSoftwarePicker -Items $itemsParaPicker -InitialFilter '' `
        -WindowTitle "Selecione o executavel encontrado na maquina teste" `
        -ColumnHeaders @("Caminho completo", "Versao do arquivo", "Modificado em")

    if (-not $selecionado) {
        Write-Log "Selecao de arquivo cancelada pelo usuario."
        return
    }

    $script:DetectionMode     = 'File'
    $script:DetectionFilePath = $selecionado.DisplayName  # aqui guardamos o FullName do arquivo

    if (-not [string]::IsNullOrWhiteSpace($selecionado.DisplayVersion)) {
        $txtVersion.Text = $selecionado.DisplayVersion
    }

    $lblDetectionMode.Text = "Modo de deteccao: ARQUIVO -> $($script:DetectionFilePath)"
    $lblDetectionMode.ForeColor = 'DarkGoldenrod'

    Write-Log "Deteccao por ARQUIVO selecionada: '$($script:DetectionFilePath)' (versao do arquivo: $($selecionado.DisplayVersion))"

    [System.Windows.Forms.MessageBox]::Show(
        "A deteccao vai usar a EXISTENCIA (e a versao do arquivo, se disponivel) deste executavel:`n`n" +
        "$($script:DetectionFilePath)`n`n" +
        "Isso substitui a deteccao por registro para esta aplicacao. Para voltar a usar o registro, " +
        "clique em 'Voltar p/ Registro'.",
        "Deteccao por arquivo selecionada",
        'OK', 'Information'
    ) | Out-Null
})

$btnClearFileDetection.Add_Click({
    $script:DetectionMode = 'Registry'
    $script:DetectionFilePath = $null
    $script:DetectedRegistryApp = $null
    $script:DetectionText = $null
    $txtDetectPattern.Text = ''
    $txtVersion.Text = ''
    $lblDetectionMode.Text = "Modo de deteccao: Registro automatico pelo Nome da Aplicacao."
    $lblDetectionMode.ForeColor = 'Gray'
    Write-Log "Modo de deteccao voltou para Registro automatico pelo Nome da Aplicacao."
})

$btnTestInstall.Add_Click({
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta primeiro.", "Aviso") | Out-Null
        return
    }
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            Write-Log "Executando instalacao de teste em $($script:RemoteTestComputer) via SCCM como SYSTEM..."
            Write-Log "A origem usada remotamente sera: $($script:OriginalSourcePath)"
            $output = Invoke-RemoteScriptAction -ComputerName $script:RemoteTestComputer -SourceFolder $script:OriginalSourcePath -ScriptInfo $script:InstallInfo
            Write-Log "  [SCCM/SYSTEM] $output"
        }
        else {
            $confirmLocal = [System.Windows.Forms.MessageBox]::Show(
                "ATENCAO: nao ha nenhuma maquina teste conectada via SCCM (grupo 3).`n`n" +
                "Isso vai executar '$($script:InstallInfo.Arquivo)' AQUI NESTE COMPUTADOR " +
                "($env:COMPUTERNAME) - que pode ser o proprio servidor do SCCM ou a estacao onde " +
                "voce esta rodando esta ferramenta.`n`n" +
                "Tem certeza que quer instalar LOCALMENTE neste computador?",
                "Confirmar execucao LOCAL (sem maquina teste conectada)",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($confirmLocal -ne 'Yes') {
                Write-Log "Instalacao local cancelada pelo usuario (nenhuma maquina teste conectada)."
                return
            }

            if (-not $script:EffectiveSourcePath) {
                throw "A pasta foi apenas inventariada pela sessao interativa. Para teste local, use uma conta com acesso direto ao UNC ou teste na maquina remota via SCCM/SYSTEM."
            }
            Write-Log "Executando instalacao de teste LOCALMENTE em: $($script:EffectiveSourcePath) (computador: $env:COMPUTERNAME)"
            Push-Location $script:EffectiveSourcePath
            if ($script:InstallInfo.Tipo -eq 'PowerShell') {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$($script:InstallInfo.Arquivo)"
            } else {
                & cmd.exe /c ".\$($script:InstallInfo.Arquivo)"
            }
            Pop-Location
        }
        Write-Log "Instalacao de teste finalizada."
    }
    catch { Write-Log "Erro na instalacao de teste: $($_.Exception.Message)" }
})

$btnTestUninstall.Add_Click({
    if (-not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta primeiro.", "Aviso") | Out-Null
        return
    }
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            Write-Log "Executando desinstalacao de teste em $($script:RemoteTestComputer) via SCCM como SYSTEM..."
            $output = Invoke-RemoteScriptAction -ComputerName $script:RemoteTestComputer -SourceFolder $script:OriginalSourcePath -ScriptInfo $script:UninstallInfo
            Write-Log "  [SCCM/SYSTEM] $output"
        }
        else {
            $confirmLocal = [System.Windows.Forms.MessageBox]::Show(
                "ATENCAO: nao ha nenhuma maquina teste conectada via SCCM (grupo 3).`n`n" +
                "Isso vai executar '$($script:UninstallInfo.Arquivo)' AQUI NESTE COMPUTADOR " +
                "($env:COMPUTERNAME) - que pode ser o proprio servidor do SCCM ou a estacao onde " +
                "voce esta rodando esta ferramenta.`n`n" +
                "Tem certeza que quer desinstalar LOCALMENTE neste computador?",
                "Confirmar execucao LOCAL (sem maquina teste conectada)",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2
            )
            if ($confirmLocal -ne 'Yes') {
                Write-Log "Desinstalacao local cancelada pelo usuario (nenhuma maquina teste conectada)."
                return
            }

            if (-not $script:EffectiveSourcePath) {
                throw "A pasta foi apenas inventariada pela sessao interativa. Para teste local, use uma conta com acesso direto ao UNC ou teste na maquina remota via SCCM/SYSTEM."
            }
            Write-Log "Executando desinstalacao de teste LOCALMENTE em: $($script:EffectiveSourcePath) (computador: $env:COMPUTERNAME)"
            Push-Location $script:EffectiveSourcePath
            if ($script:UninstallInfo.Tipo -eq 'PowerShell') {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$($script:UninstallInfo.Arquivo)"
            } else {
                & cmd.exe /c ".\$($script:UninstallInfo.Arquivo)"
            }
            Pop-Location
        }
        Write-Log "Desinstalacao de teste finalizada."
    }
    catch { Write-Log "Erro na desinstalacao de teste: $($_.Exception.Message)" }
})

function Build-CurrentDetectionText {
    <#
        Registro: usa EXCLUSIVAMENTE a entrada que foi descoberta na maquina
        teste a partir do Nome da Aplicacao. O campo Versao e apenas o reflexo
        da DisplayVersion encontrada; ele nao e criterio de descoberta.
    #>
    if ($script:DetectionMode -eq 'File' -and $script:DetectionFilePath) {
        return New-FileDetectionScriptText -FilePath $script:DetectionFilePath -MinVersion $txtVersion.Text
    }

    if (-not $script:DetectedRegistryApp) {
        [System.Windows.Forms.MessageBox]::Show(
            "Primeiro clique em 'Gerar Deteccao pelo Nome da Aplicacao'.`n`nA ferramenta precisa consultar a maquina teste e descobrir o DisplayName/DisplayVersion reais no registro.",
            "Deteccao ainda nao gerada", 'OK', 'Warning') | Out-Null
        return $null
    }

    $realName = [string]$script:DetectedRegistryApp.DisplayName
    $realVersion = [string]$script:DetectedRegistryApp.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($realName) -or [string]::IsNullOrWhiteSpace($realVersion)) { return $null }

    # Reafirma os valores descobertos para evitar que uma digitacao manual
    # posterior altere silenciosamente o Detection Method.
    $txtDetectPattern.Text = $realName
    $txtVersion.Text = $realVersion
    return New-DetectionScriptText -DisplayNamePattern $realName -MinVersion $realVersion
}

$btnTestDetection.Add_Click({
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            if ($script:DetectionMode -eq 'File' -and $script:DetectionFilePath) {
                Write-Log "Testando deteccao por ARQUIVO em $($script:RemoteTestComputer) via SCCM/SYSTEM: $($script:DetectionFilePath)"
                $raw = Invoke-RemoteDetection -ComputerName $script:RemoteTestComputer -FilePath $script:DetectionFilePath -MinVersion $txtVersion.Text
            }
            else {
                if (-not $script:DetectedRegistryApp) {
                    [System.Windows.Forms.MessageBox]::Show("Primeiro gere a deteccao automaticamente pelo Nome da Aplicacao.", "Aviso") | Out-Null
                    return
                }
                $realName = [string]$script:DetectedRegistryApp.DisplayName
                $realVersion = [string]$script:DetectedRegistryApp.DisplayVersion
                Write-Log "Testando deteccao por REGISTRO em $($script:RemoteTestComputer) via SCCM/SYSTEM: DisplayName real='$realName', versao descoberta=$realVersion"
                $raw = Invoke-RemoteDetection -ComputerName $script:RemoteTestComputer -DisplayNamePattern $realName -MinVersion $realVersion
            }

            $obj = $null
            try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch {}

            if (-not $obj) {
                Write-Log "Nao foi possivel interpretar o retorno da maquina teste. Retorno bruto: $raw"
                return
            }

            Write-Log "Contexto remoto: $($obj.Identity)"

            if ($obj.Correspondencias -and $obj.Correspondencias.Count -gt 0) {
                Write-Log "Candidatos encontrados no registro (nome bateu, mesmo que a versao nao bata ainda):"
                foreach ($linha in $obj.Correspondencias) { Write-Log "  - $linha" }
            }
            elseif ($script:DetectionMode -ne 'File') {
                Write-Log "NENHUM candidato encontrado com esse padrao de nome em HKLM/WOW6432Node/HKU nessa maquina."
            }

            if ($script:DetectionMode -eq 'File') {
                Write-Log "Arquivo existe? $($obj.Existe) | Versao do arquivo: $($obj.FileVersion)"
            }

            if ($obj.Result -eq 'Instalado') {
                Write-Log "RESULTADO: Instalado (deteccao OK)"
            } else {
                Write-Log "RESULTADO: Nao detectado."
            }
        }
        else {
            $script:DetectionText = Build-CurrentDetectionText
            if (-not $script:DetectionText) { return }

            Write-Log "Sem maquina teste conectada via SCCM - executando script de deteccao LOCALMENTE neste computador ($env:COMPUTERNAME)."
            $resultado = Invoke-Expression $script:DetectionText

            if (($resultado | Out-String).Trim() -eq 'Instalado') {
                Write-Log "RESULTADO: Instalado (deteccao OK)"
            }
            else {
                Write-Log "RESULTADO: Nao detectado. Retorno: $(($resultado | Out-String).Trim())"
            }
        }
    }
    catch { Write-Log "Erro ao rodar deteccao: $($_.Exception.Message)" }
})

$btnCreate.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtAppName.Text) -or [string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Preencha Nome da Aplicacao e Pasta de Origem.", "Aviso") | Out-Null
        return
    }
    if ($script:DetectionMode -eq 'Registry' -and -not $script:DetectedRegistryApp) {
        [System.Windows.Forms.MessageBox]::Show("Antes de criar a aplicacao, clique em 'Gerar Deteccao pelo Nome da Aplicacao' para descobrir a versao real no registro da maquina teste.", "Aviso") | Out-Null
        return
    }
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado -or
        -not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado -or
        -not $script:OriginalSourcePath) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta e confirme que install/uninstall foram encontrados.", "Aviso") | Out-Null
        return
    }

    $sourceNow = Get-CleanPath -Path $txtSourceFolder.Text
    if ($sourceNow -ne $script:OriginalSourcePath) {
        [System.Windows.Forms.MessageBox]::Show("A Pasta de Origem foi alterada depois do ultimo scan. Escaneie novamente antes de criar a aplicacao.", "Source alterado", 'OK', 'Warning') | Out-Null
        return
    }

    $script:DetectionText = Build-CurrentDetectionText
    if (-not $script:DetectionText) { return }

    $descricaoDeteccao = if ($script:DetectionMode -eq 'File') {
        "Arquivo: $($script:DetectionFilePath)"
    } else {
        "Registro AUTO: DisplayName='$($script:DetectedRegistryApp.DisplayName)', versao encontrada=$($script:DetectedRegistryApp.DisplayVersion)"
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Confirma a criacao da aplicacao '$($txtAppName.Text)' no SCCM?`n`n" +
        "Content Location (UNC real usado pelo SCCM):`n$($script:OriginalSourcePath)`n`n" +
        "Metodo de deteccao: $descricaoDeteccao",
        "Confirmar",
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )
    if ($confirm -ne 'Yes') { return }

    Write-Log "Criando aplicacao '$($txtAppName.Text)' no SCCM (ContentLocation: $($script:OriginalSourcePath))..."
    $result = New-SCCMScriptApplication `
        -AppName $txtAppName.Text `
        -Publisher $txtPublisher.Text `
        -Version $txtVersion.Text `
        -SourceFolder $script:OriginalSourcePath `
        -InstallCommand $script:InstallInfo.Comando `
        -UninstallCommand $script:UninstallInfo.Comando `
        -DetectionScript $script:DetectionText

    if ($result.Sucesso) {
        Write-Log $result.Mensagem
        [System.Windows.Forms.MessageBox]::Show($result.Mensagem, "Sucesso") | Out-Null
    } else {
        Write-Log "ERRO: $($result.Mensagem)"
        [System.Windows.Forms.MessageBox]::Show($result.Mensagem, "Erro", 'OK', 'Error') | Out-Null
    }
})

$form.Add_FormClosing({
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }
})

Write-Log "Ferramenta iniciada. Conecte ao SCCM e preencha os dados da aplicacao."
[void]$form.ShowDialog()
