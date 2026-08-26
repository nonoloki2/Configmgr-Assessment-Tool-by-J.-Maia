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

# ----------------------------------------------------------------------------
# FUNCOES DE LOGICA (separadas da GUI para poderem ser reaproveitadas/testadas)
# ----------------------------------------------------------------------------

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
        Gera o TEXTO do script de deteccao em PowerShell que sera colocado
        no Deployment Type do SCCM (Detection Method = Script).
        Varre:
          - HKLM\...\Uninstall            (apps 64-bit nativos)
          - HKLM\...\WOW6432Node\Uninstall (apps 32-bit em SO 64-bit)
          - HKCU\...\Uninstall            (apps instalados por usuario)
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayNamePattern,
        [Parameter(Mandatory)][string]$MinVersion
    )

    return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$displayNamePattern = '$DisplayNamePattern'
`$minVersion = [version]'$MinVersion'

`$uninstallPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

`$apps = Get-ItemProperty -Path `$uninstallPaths |
    Where-Object { `$_.DisplayName -like "*`$displayNamePattern*" -and `$_.DisplayVersion }

foreach (`$app in `$apps) {
    try {
        `$installedVersion = [version](`$app.DisplayVersion -replace '[^0-9.]', '')
        if (`$installedVersion -ge `$minVersion) {
            Write-Output "Instalado"
            break
        }
    }
    catch { }
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

# ----------------------------------------------------------------------------
# GUI
# ----------------------------------------------------------------------------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "SCCM App Creator - Aplicacoes baseadas em Script"
$form.Size             = New-Object System.Drawing.Size(720, 700)
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
$grpApp.Size = New-Object System.Drawing.Size(690, 175)
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
$lblVersion.Text = "Versao (ex: 1.2.3):"
$lblVersion.Location = New-Object System.Drawing.Point(10, 85)
$lblVersion.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblVersion)

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Location = New-Object System.Drawing.Point(140, 82)
$txtVersion.Size = New-Object System.Drawing.Size(150, 20)
$grpApp.Controls.Add($txtVersion)

$lblDetectPattern = New-Object System.Windows.Forms.Label
$lblDetectPattern.Text = "Padrao DisplayName (registro):"
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
$txtSourceFolder.Size = New-Object System.Drawing.Size(400, 20)
$grpApp.Controls.Add($txtSourceFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "..."
$btnBrowse.Location = New-Object System.Drawing.Point(545, 111)
$btnBrowse.Size = New-Object System.Drawing.Size(35, 23)
$grpApp.Controls.Add($btnBrowse)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = "Escanear Pasta"
$btnScan.Location = New-Object System.Drawing.Point(590, 111)
$btnScan.Size = New-Object System.Drawing.Size(90, 23)
$grpApp.Controls.Add($btnScan)

$lblScanResult = New-Object System.Windows.Forms.Label
$lblScanResult.Text = "Instalacao: -- | Desinstalacao: --"
$lblScanResult.Location = New-Object System.Drawing.Point(10, 145)
$lblScanResult.Size = New-Object System.Drawing.Size(670, 20)
$grpApp.Controls.Add($lblScanResult)

# --- Grupo: Comandos gerados ---
$grpCmds = New-Object System.Windows.Forms.GroupBox
$grpCmds.Text = "3. Linhas geradas (SCCM Deployment Type)"
$grpCmds.Location = New-Object System.Drawing.Point(10, 295)
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

# --- Grupo: Testes locais (na maquina teste) ---
$grpTest = New-Object System.Windows.Forms.GroupBox
$grpTest.Text = "4. Testes locais (opcional - roda na maquina atual)"
$grpTest.Location = New-Object System.Drawing.Point(10, 435)
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
$txtLog.Location = New-Object System.Drawing.Point(10, 505)
$txtLog.Size = New-Object System.Drawing.Size(690, 140)
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
        $lblConnStatus.Text = $result.Mensagem
        $lblConnStatus.ForeColor = 'Green'
    } else {
        $lblConnStatus.Text = "Falha: $($result.Mensagem)"
        $lblConnStatus.ForeColor = 'Red'
    }
    Write-Log $result.Mensagem
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtSourceFolder.Text = $dlg.SelectedPath
    }
})

$btnScan.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text) -or -not (Test-Path $txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma pasta de origem valida.", "Aviso") | Out-Null
        return
    }

    $script:InstallInfo   = Get-InstallCommandLine -FolderPath $txtSourceFolder.Text -Action 'install'
    $script:UninstallInfo = Get-InstallCommandLine -FolderPath $txtSourceFolder.Text -Action 'uninstall'

    $installStatus   = if ($script:InstallInfo.Encontrado)   { "$($script:InstallInfo.Tipo) ($($script:InstallInfo.Arquivo))" }   else { "NAO ENCONTRADO" }
    $uninstallStatus = if ($script:UninstallInfo.Encontrado) { "$($script:UninstallInfo.Tipo) ($($script:UninstallInfo.Arquivo))" } else { "NAO ENCONTRADO" }
    $lblScanResult.Text = "Instalacao: $installStatus | Desinstalacao: $uninstallStatus"

    if ($script:InstallInfo.Encontrado)   { $txtInstallCmd.Text   = $script:InstallInfo.Comando }   else { $txtInstallCmd.Text = "" }
    if ($script:UninstallInfo.Encontrado) { $txtUninstallCmd.Text = $script:UninstallInfo.Comando } else { $txtUninstallCmd.Text = "" }

    if (-not $script:InstallInfo.Encontrado -or -not $script:UninstallInfo.Encontrado) {
        Write-Log "ATENCAO: nao foram encontrados install.ps1/.bat e/ou uninstall.ps1/.bat na pasta."
    } else {
        Write-Log "Scripts encontrados. Install: $($script:InstallInfo.Comando) | Uninstall: $($script:UninstallInfo.Comando)"
    }

    if ([string]::IsNullOrWhiteSpace($txtDetectPattern.Text) -and -not [string]::IsNullOrWhiteSpace($txtAppName.Text)) {
        $txtDetectPattern.Text = $txtAppName.Text
    }
})

$btnTestInstall.Add_Click({
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta primeiro.", "Aviso") | Out-Null
        return
    }
    Write-Log "Executando instalacao de teste em: $($txtSourceFolder.Text)"
    try {
        Push-Location $txtSourceFolder.Text
        if ($script:InstallInfo.Tipo -eq 'PowerShell') {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$($script:InstallInfo.Arquivo)"
        } else {
            & cmd.exe /c ".\$($script:InstallInfo.Arquivo)"
        }
        Write-Log "Instalacao de teste finalizada (verifique o resultado na maquina)."
    }
    catch { Write-Log "Erro na instalacao de teste: $($_.Exception.Message)" }
    finally { Pop-Location }
})

$btnTestUninstall.Add_Click({
    if (-not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta primeiro.", "Aviso") | Out-Null
        return
    }
    Write-Log "Executando desinstalacao de teste em: $($txtSourceFolder.Text)"
    try {
        Push-Location $txtSourceFolder.Text
        if ($script:UninstallInfo.Tipo -eq 'PowerShell') {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\$($script:UninstallInfo.Arquivo)"
        } else {
            & cmd.exe /c ".\$($script:UninstallInfo.Arquivo)"
        }
        Write-Log "Desinstalacao de teste finalizada (verifique o resultado na maquina)."
    }
    catch { Write-Log "Erro na desinstalacao de teste: $($_.Exception.Message)" }
    finally { Pop-Location }
})

$btnTestDetection.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtDetectPattern.Text) -or [string]::IsNullOrWhiteSpace($txtVersion.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Preencha o padrao do DisplayName e a Versao.", "Aviso") | Out-Null
        return
    }
    $script:DetectionText = New-DetectionScriptText -DisplayNamePattern $txtDetectPattern.Text -MinVersion $txtVersion.Text
    Write-Log "Executando script de deteccao localmente..."
    try {
        $resultado = Invoke-Expression $script:DetectionText
        if ($resultado -eq "Instalado") {
            Write-Log "RESULTADO: Instalado (deteccao OK)"
        } else {
            Write-Log "RESULTADO: Nao detectado."
        }
    }
    catch { Write-Log "Erro ao rodar deteccao: $($_.Exception.Message)" }
})

$btnCreate.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtAppName.Text) -or [string]::IsNullOrWhiteSpace($txtVersion.Text) -or
        [string]::IsNullOrWhiteSpace($txtSourceFolder.Text) -or [string]::IsNullOrWhiteSpace($txtDetectPattern.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Preencha Nome, Versao, Pasta de Origem e o padrao de deteccao.", "Aviso") | Out-Null
        return
    }
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado -or
        -not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado) {
        [System.Windows.Forms.MessageBox]::Show("Escaneie a pasta e confirme que install/uninstall foram encontrados.", "Aviso") | Out-Null
        return
    }

    $script:DetectionText = New-DetectionScriptText -DisplayNamePattern $txtDetectPattern.Text -MinVersion $txtVersion.Text

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Confirma a criacao da aplicacao '$($txtAppName.Text)' no SCCM?",
        "Confirmar",
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )
    if ($confirm -ne 'Yes') { return }

    Write-Log "Criando aplicacao '$($txtAppName.Text)' no SCCM..."
    $result = New-SCCMScriptApplication `
        -AppName $txtAppName.Text `
        -Publisher $txtPublisher.Text `
        -Version $txtVersion.Text `
        -SourceFolder $txtSourceFolder.Text `
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

Write-Log "Ferramenta iniciada. Conecte ao SCCM e preencha os dados da aplicacao."
[void]$form.ShowDialog()
