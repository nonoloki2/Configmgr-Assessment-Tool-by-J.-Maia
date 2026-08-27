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

# ============================================================================
# WINDOWS 11 VISUAL STYLE ADD-ON (100% aditivo)
# ----------------------------------------------------------------------------
# Este bloco NAO altera nenhuma funcao, evento ou variavel de logica do
# script original. Ele apenas aplica, de forma cosmetica, cantos arredondados,
# modo escuro/claro automatico, Mica e restyle Fluent nos controles WinForms
# ja existentes, atraves das APIs nativas do DWM (Windows 11).
# ============================================================================

if (-not ("Win11Style.NativeMethods" -as [type])) {
    Add-Type -Namespace Win11Style -Name NativeMethods -MemberDefinition @"
        [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int attrValue, int attrSize);
"@
}

# Constantes do DWM (Windows 11)
$script:DWMWA_USE_IMMERSIVE_DARK_MODE   = 20
$script:DWMWA_WINDOW_CORNER_PREFERENCE  = 33
$script:DWMWA_SYSTEMBACKDROP_TYPE       = 38
$script:DWMWCP_ROUND                    = 2
$script:DWMSBT_MAINWINDOW               = 2   # Mica

function Get-Win11ThemeInfo {
    <# Le o tema atual do sistema (claro/escuro) e a cor de destaque (accent). #>
    $isLight = $true
    try {
        $personalize = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        $isLight = [bool]$personalize.AppsUseLightTheme
    } catch { }

    $accent = [System.Drawing.Color]::FromArgb(0, 120, 212)  # azul padrao Win11
    try {
        $accentRaw = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -ErrorAction Stop).AccentColorMenu
        $bytes = [System.BitConverter]::GetBytes([uint32]$accentRaw)
        $accent = [System.Drawing.Color]::FromArgb(255, $bytes[0], $bytes[1], $bytes[2])
    } catch { }

    if ($isLight) {
        [PSCustomObject]@{
            IsLight    = $true
            FormBack   = [System.Drawing.Color]::FromArgb(243, 243, 243)
            PanelBack  = [System.Drawing.Color]::White
            Text       = [System.Drawing.Color]::FromArgb(32, 32, 32)
            BorderCol  = [System.Drawing.Color]::FromArgb(200, 200, 200)
            Accent     = $accent
        }
    } else {
        [PSCustomObject]@{
            IsLight    = $false
            FormBack   = [System.Drawing.Color]::FromArgb(32, 32, 32)
            PanelBack  = [System.Drawing.Color]::FromArgb(44, 44, 44)
            Text       = [System.Drawing.Color]::FromArgb(240, 240, 240)
            BorderCol  = [System.Drawing.Color]::FromArgb(70, 70, 70)
            Accent     = $accent
        }
    }
}

function Set-RoundedRegion {
    <# Aplica cantos arredondados via Region a um controle (ex: botoes). #>
    param([System.Windows.Forms.Control]$Control, [int]$Radius = 6)
    if ($Control.Width -le 0 -or $Control.Height -le 0) { return }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Control.Width, $Control.Height)
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $Control.Region = New-Object System.Drawing.Region($path)
}

function Set-Win11ControlStyle {
    <# Restiliza recursivamente os controles ja criados pelo script, sem tocar em nenhum handler/evento/logica. #>
    param([System.Windows.Forms.Control]$Root, [PSCustomObject]$Theme)

    $fontName = 'Segoe UI Variable Display'
    if (-not ([System.Drawing.FontFamily]::Families | Where-Object { $_.Name -eq $fontName })) {
        $fontName = 'Segoe UI'
    }

    foreach ($ctrl in $Root.Controls) {
        switch ($ctrl.GetType().Name) {
            'Button' {
                $ctrl.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                $ctrl.FlatAppearance.BorderSize = 1
                $ctrl.FlatAppearance.BorderColor = $Theme.BorderCol
                $ctrl.BackColor = $Theme.PanelBack
                $ctrl.ForeColor = $Theme.Text
                $ctrl.Font = New-Object System.Drawing.Font($fontName, 9)
                $ctrl.Cursor = [System.Windows.Forms.Cursors]::Hand
                Set-RoundedRegion -Control $ctrl -Radius 6
            }
            'TextBox' {
                $ctrl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $ctrl.BackColor = $Theme.PanelBack
                $ctrl.ForeColor = $Theme.Text
                $ctrl.Font = New-Object System.Drawing.Font($fontName, 9)
            }
            'Label' {
                $ctrl.ForeColor = $Theme.Text
                $ctrl.Font = New-Object System.Drawing.Font($fontName, 9)
            }
            'GroupBox' {
                $ctrl.ForeColor = $Theme.Accent
                $ctrl.Font = New-Object System.Drawing.Font($fontName, 9, [System.Drawing.FontStyle]::Bold)
            }
            'ListView' {
                $ctrl.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
                $ctrl.BackColor = $Theme.PanelBack
                $ctrl.ForeColor = $Theme.Text
            }
        }
        if ($ctrl.Controls -and $ctrl.Controls.Count -gt 0) {
            Set-Win11ControlStyle -Root $ctrl -Theme $Theme
        }
    }
}

function Enable-Windows11Style {
    <#
        Ponto de entrada unico do add-on visual. Chame passando o $form.
        Nao modifica nenhuma variavel de estado do script original, apenas
        aplica estilo visual em cima dos controles ja existentes.
    #>
    param([System.Windows.Forms.Form]$FormObject)

    $theme = Get-Win11ThemeInfo
    $FormObject.BackColor = $theme.FormBack

    Set-Win11ControlStyle -Root $FormObject -Theme $theme

    $applyDwm = {
        try {
            $hwnd = $FormObject.Handle
            $corner = $script:DWMWCP_ROUND
            [Win11Style.NativeMethods]::DwmSetWindowAttribute($hwnd, $script:DWMWA_WINDOW_CORNER_PREFERENCE, [ref]$corner, 4) | Out-Null

            $darkMode = if ($theme.IsLight) { 0 } else { 1 }
            [Win11Style.NativeMethods]::DwmSetWindowAttribute($hwnd, $script:DWMWA_USE_IMMERSIVE_DARK_MODE, [ref]$darkMode, 4) | Out-Null

            $backdrop = $script:DWMSBT_MAINWINDOW
            [Win11Style.NativeMethods]::DwmSetWindowAttribute($hwnd, $script:DWMWA_SYSTEMBACKDROP_TYPE, [ref]$backdrop, 4) | Out-Null
        } catch {
            Write-Verbose "Win11Style: nao foi possivel aplicar atributos DWM ($_)"
        }
    }

    if ($FormObject.IsHandleCreated) { & $applyDwm } else { $FormObject.Add_HandleCreated({ & $applyDwm }) }
}

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
            Success=$false
            Mensagem="Unable to identify the interactive session user: $($_.Exception.Message)"
        }
    }

    if (-not $explorerProc -or -not $explorerProc.UserName) {
        return [pscustomobject]@{
            Success=$false
            Mensagem='No interactive session with explorer.exe was found.'
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
                Success=$false
                Mensagem="Folder scan did not return within 30 seconds as '$interactiveUser' (session $interactiveSessionId)."
            }
        }

        $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $result.Success) {
            return [pscustomobject]@{
                Success=$false
                Mensagem="User '$interactiveUser' (session $interactiveSessionId) could NOT enumerate UNC '$SourcePath'. Actual error: $($result.Error)"
            }
        }

        function New-ManifestCommandInfo {
            param([bool]$Ps1,[bool]$Bat,[string]$Action)
            # Wrapper .BAT tem prioridade quando existe.
            if ($Bat) {
                return [pscustomobject]@{ Encontrado=$true; Tipo='Batch'; Arquivo="$Action.bat"; Comando="cmd.exe /c `"$Action.bat`"" }
            }
            if ($Ps1) {
                return [pscustomobject]@{ Encontrado=$true; Tipo='PowerShell'; Arquivo="$Action.ps1"; Comando="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$Action.ps1`"" }
            }
            return [pscustomobject]@{ Encontrado=$false; Tipo=$null; Arquivo=$null; Comando=$null }
        }

        $filesFound = @($result.Files)
        $fileSummary = if ($filesFound.Count -gt 0) { $filesFound -join ', ' } else { '<empty folder>' }

        return [pscustomobject]@{
            Success = $true
            Mensagem = "UNC successfully enumerated as '$interactiveUser' (session $interactiveSessionId). Files in root: $fileSummary"
            InstallInfo = New-ManifestCommandInfo -Ps1 ([bool]$result.InstallPs1) -Bat ([bool]$result.InstallBat) -Action 'install'
            UninstallInfo = New-ManifestCommandInfo -Ps1 ([bool]$result.UninstallPs1) -Bat ([bool]$result.UninstallBat) -Action 'uninstall'
            Files = $filesFound
        }
    }
    catch {
        return [pscustomobject]@{ Success=$false; Mensagem=$_.Exception.Message }
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
          Success           - bool
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
            return [PSCustomObject]@{ Success = $true; CaminhoEfetivo = 'SCCMSRC:\'; Mensagem = "Access using alternate credentials succeeded." }
        }
        catch {
            return [PSCustomObject]@{ Success = $false; CaminhoEfetivo = $null; Mensagem = $_.Exception.Message }
        }
    }
    else {
        if (Test-Path -LiteralPath $Path) {
            return [PSCustomObject]@{ Success = $true; CaminhoEfetivo = $Path; Mensagem = "Access using the current account succeeded." }
        }
        else {
            return [PSCustomObject]@{ Success = $false; CaminhoEfetivo = $null; Mensagem = "Test-Path returned false (no additional error details)." }
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

    # Para esta ferramenta, wrappers .BAT sao preferidos quando existem.
    # Eles representam exatamente a logica de instalacao/desinstalacao ja validada
    # pelo operador (incluindo timeout, tratamento de exit code etc.).
    if (Test-Path -LiteralPath $batPath) {
        return [PSCustomObject]@{
            Encontrado = $true
            Tipo       = 'Batch'
            Arquivo    = "$Action.bat"
            Comando    = "cmd.exe /c `"$Action.bat`""
        }
    }
    elseif (Test-Path -LiteralPath $ps1Path) {
        return [PSCustomObject]@{
            Encontrado = $true
            Tipo       = 'PowerShell'
            Arquivo    = "$Action.ps1"
            Comando    = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$Action.ps1`""
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
        Write-Output 'Installed'
        exit 0
    }
}
"@
}


function New-ExactRegistryDetectionScriptText {
    <#
        Detection Method FINAL: usa a chave EXATA descoberta na maquina teste.
        Nao varre todo o Uninstall durante a avaliacao do SCCM.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$MinVersion,
        [Parameter(Mandatory)][string]$RegistrySubKey,
        [Parameter(Mandatory)][ValidateSet('HKLM','HKU')][string]$RegistryHive,
        [ValidateSet('32','64','Default')][string]$RegistryView = 'Default'
    )

    $safeName    = $DisplayName.Replace("'", "''")
    $safeVersion = $MinVersion.Replace("'", "''")
    $safeSubKey  = $RegistrySubKey.Replace("'", "''")

    return @"
`$ErrorActionPreference = 'SilentlyContinue'
`$expectedName = '$safeName'
`$expectedVersionText = '$safeVersion'
`$subKey = '$safeSubKey'
`$hive = '$RegistryHive'
`$view = '$RegistryView'

function Convert-AppVersion([string]`$Text) {
    if ([string]::IsNullOrWhiteSpace(`$Text)) { return `$null }
    `$m = [regex]::Match(`$Text, '\d+(?:\.\d+){0,3}')
    if (-not `$m.Success) { return `$null }
    `$parts = @(`$m.Value.Split('.') | ForEach-Object { [int]`$_ })
    while (`$parts.Count -lt 4) { `$parts += 0 }
    try { return [version]::new(`$parts[0],`$parts[1],`$parts[2],`$parts[3]) } catch { return `$null }
}

`$baseHive = if (`$hive -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::Users }
`$registryView = switch (`$view) {
    '32' { [Microsoft.Win32.RegistryView]::Registry32 }
    '64' { [Microsoft.Win32.RegistryView]::Registry64 }
    default { [Microsoft.Win32.RegistryView]::Default }
}

try {
    `$baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(`$baseHive, `$registryView)
    try {
        `$key = `$baseKey.OpenSubKey(`$subKey)
        if (-not `$key) { exit 0 }
        try {
            `$name = [string]`$key.GetValue('DisplayName', '')
            `$installedVersionText = [string]`$key.GetValue('DisplayVersion', '')
        }
        finally { `$key.Dispose() }
    }
    finally { `$baseKey.Dispose() }
}
catch { exit 0 }

if (`$name -ne `$expectedName) { exit 0 }
`$installed = Convert-AppVersion `$installedVersionText
`$minimum = Convert-AppVersion `$expectedVersionText
if (`$installed -and `$minimum -and `$installed -ge `$minimum) {
    Write-Output 'Installed'
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
    Write-Output "Installed"
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
            Write-Output "Installed"
        }
    }
    catch {
        # Se o arquivo nao tiver informacao de versao legivel, considera
        # instalado apenas pela existencia (mais permissivo que falhar).
        Write-Output "Installed"
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
            throw "SMS_ADMIN_UI_PATH environment variable was not found. The SCCM Console must be installed on this machine."
        }

        if (-not (Get-Module ConfigurationManager)) {
            $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1'
            Import-Module $modulePath -ErrorAction Stop
        }

        if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop | Out-Null
        }

        Set-Location "$($SiteCode):\"
        return [PSCustomObject]@{ Success = $true; Mensagem = "Connected to $SiteServer ($SiteCode)" }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Mensagem = $_.Exception.Message }
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
        if ([string]::IsNullOrWhiteSpace($DisplayNamePattern)) { throw 'DisplayNamePattern was not provided.' }
        if ([string]::IsNullOrWhiteSpace($MinVersion)) { throw 'MinVersion was not provided.' }

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
            Result           = if ($detected) { 'Installed' } else { 'NotInstalled' }
            Correspondencias = $detalhes
        } | ConvertTo-Json -Compress -Depth 3
    }

    'RunFileDetection' {
        if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'FilePath was not provided.' }

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
            Result       = if ($detected) { 'Installed' } else { 'NotInstalled' }
        } | ConvertTo-Json -Compress
    }

    'RunSourceScript' {
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'SourcePath was not provided.' }
        if ([string]::IsNullOrWhiteSpace($ScriptFile)) { throw 'ScriptFile was not provided.' }
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            throw "SYSTEM could not access the source folder: $SourcePath"
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
                throw "Unsupported script type: $ScriptType"
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
                    @{Name='Escopo'; Expression={'Machine (HKLM)'}}
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
        if ([string]::IsNullOrWhiteSpace($NamePattern)) { throw 'NamePattern was not provided.' }

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
            throw "Unable to locate/create helper '$ScriptName'."
        }

        # ApprovalState 3 = Approved. Em ambientes onde o autor nao pode
        # aprovar o proprio script, a tentativa abaixo falha e a GUI explica
        # que a aprovacao precisa ser feita uma unica vez por outro admin.
        if ([int]$helper.ApprovalState -ne 3) {
            try {
                Approve-CMScript -InputObject $helper -Comment 'SCCM App Creator helper for SYSTEM-context operations.' -Confirm:$false -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 500
                $helper = Get-CMScript -ScriptName $ScriptName -Fast -ErrorAction Stop |
                    Where-Object { $_.ScriptName -eq $ScriptName } |
                    Select-Object -First 1
            }
            catch {
                return [PSCustomObject]@{
                    Success = $false
                    Helper  = $helper
                    PrecisaAprovacao = $true
                    Mensagem = "Helper '$ScriptName' was created but still needs to be APPROVED in SCCM under Software Library > Scripts. By default, the author cannot approve their own script. After approval, click Connect via SCCM / SYSTEM again."
                }
            }
        }

        if ([int]$helper.ApprovalState -ne 3) {
            return [PSCustomObject]@{
                Success = $false
                Helper  = $helper
                PrecisaAprovacao = $true
                Mensagem = "Helper '$ScriptName' exists but is not approved in SCCM yet."
            }
        }

        return [PSCustomObject]@{ Success = $true; Helper = $helper; PrecisaAprovacao = $false; Mensagem = "Helper '$ScriptName' approved and ready." }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Helper = $null; PrecisaAprovacao = $false; Mensagem = $_.Exception.Message }
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
            throw "Failed to query Run Script result from the SMS Provider: $($_.Exception.Message)"
        }

        if ($status) {
            $sawStatus = $true
            $scriptError = [string]$status.ScriptError
            if (-not [string]::IsNullOrWhiteSpace($scriptError)) {
                throw "Run Script returned an error on the machine: $scriptError"
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
        throw "The client responded to Run Script, but the SMS Provider did not make the payload available in SMS_ScriptsExecutionSummary after $TimeoutSeconds seconds. OperationID=$OperationID TaskID=$taskId."
    }

    throw "Timed out waiting for the machine to respond through SCCM after $TimeoutSeconds seconds. Check Scripts.log/CcmMessaging.log."
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
        throw "Machine '$ComputerName' was not found as a device in SCCM."
    }

    $helperResult = Ensure-CMAppCreatorHelperScript
    if (-not $helperResult.Success) {
        throw $helperResult.Mensagem
    }

    $params = @{ Action = $Action }

    if ($Action -eq 'RunSourceScript') {
        if (-not $ScriptInfo) { throw 'Install/uninstall script information was not provided.' }
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'Source folder was not provided.' }
        $params.SourcePath = $SourcePath
        $params.ScriptType = $ScriptInfo.Tipo
        $params.ScriptFile = $ScriptInfo.Arquivo
    }
    elseif ($Action -eq 'FindExecutable') {
        if ([string]::IsNullOrWhiteSpace($NamePattern)) { throw 'File name pattern was not provided.' }
        $params.NamePattern = $NamePattern
        if (-not [string]::IsNullOrWhiteSpace($ExtraRoots)) { $params.ExtraRoots = $ExtraRoots }
    }
    elseif ($Action -eq 'RunRegistryDetection') {
        if ([string]::IsNullOrWhiteSpace($DisplayNamePattern)) { throw 'DisplayName pattern was not provided.' }
        if ([string]::IsNullOrWhiteSpace($MinVersion)) { throw 'Minimum version was not provided.' }
        $params.DisplayNamePattern = $DisplayNamePattern
        $params.MinVersion = $MinVersion
    }
    elseif ($Action -eq 'RunFileDetection') {
        if ([string]::IsNullOrWhiteSpace($FilePath)) { throw 'File path was not provided.' }
        $params.FilePath = $FilePath
        if (-not [string]::IsNullOrWhiteSpace($MinVersion)) { $params.MinVersion = $MinVersion }
    }

    $invoke = Invoke-CMScript -ScriptGuid $helperResult.Helper.ScriptGuid -Device $device -ScriptParameter $params -PassThru -Confirm:$false -ErrorAction Stop
    if (-not $invoke -or -not $invoke.OperationID) {
        throw 'SCCM did not return an OperationID for the Run Script execution.'
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
            Success  = $true
            Mensagem = if ($identity) { "Machine responded through SCCM. Remote context: $identity" } else { "Machine responded to SCCM Run Script. Logical connection validated." }
            Output   = $output
        }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Mensagem = $_.Exception.Message; Output = $null }
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


function Get-RemoteRegistryStringValue {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][uint32]$Hive,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$ValueName
    )
    try {
        $r = Invoke-CimMethod -CimSession $CimSession -Namespace 'root\default' -ClassName 'StdRegProv' `
            -MethodName 'GetStringValue' -Arguments @{ hDefKey=$Hive; sSubKeyName=$SubKey; sValueName=$ValueName } -ErrorAction Stop
        if ($r.ReturnValue -eq 0) { return [string]$r.sValue }
    } catch {}
    return $null
}

function Get-RemoteRegistryDwordValue {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][uint32]$Hive,
        [Parameter(Mandatory)][string]$SubKey,
        [Parameter(Mandatory)][string]$ValueName
    )
    try {
        $r = Invoke-CimMethod -CimSession $CimSession -Namespace 'root\default' -ClassName 'StdRegProv' `
            -MethodName 'GetDWORDValue' -Arguments @{ hDefKey=$Hive; sSubKeyName=$SubKey; sValueName=$ValueName } -ErrorAction Stop
        if ($r.ReturnValue -eq 0) { return [uint32]$r.uValue }
    } catch {}
    return $null
}

function Get-RemoteRegistrySubKeys {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][uint32]$Hive,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubKey
    )
    try {
        $r = Invoke-CimMethod -CimSession $CimSession -Namespace 'root\default' -ClassName 'StdRegProv' `
            -MethodName 'EnumKey' -Arguments @{ hDefKey=$Hive; sSubKeyName=$SubKey } -ErrorAction Stop
        if ($r.ReturnValue -eq 0 -and $r.sNames) { return @($r.sNames) }
    } catch {}
    return @()
}


function Invoke-RemoteCommandDirect {
    <#
        Executa uma linha de comando diretamente na maquina teste via WMI/DCOM
        (Win32_Process.Create). Nao usa SCCM Run Script, ScriptOutput ou payload.
        Mantem a GUI responsiva enquanto aguarda o processo remoto terminar.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$CommandLine,
        [int]$TimeoutSeconds = 180
    )

    $session = $null
    try {
        $opt = New-CimSessionOption -Protocol Dcom
        $session = New-CimSession -ComputerName $ComputerName -SessionOption $opt -OperationTimeoutSec 15 -ErrorAction Stop

        $cmd = $CommandLine.Trim()
        if ([string]::IsNullOrWhiteSpace($cmd)) { throw "Linha de comando vazia." }

        # .bat/.cmd e comandos com operadores do shell precisam de cmd.exe.
        if ($cmd -match '(?i)\.(bat|cmd)(\s|$)' -or $cmd -match '[&|<>]') {
            $escaped = $cmd.Replace('"','\"')
            $cmd = 'cmd.exe /d /s /c "' + $escaped + '"'
        }

        $create = Invoke-CimMethod -CimSession $session -ClassName Win32_Process -MethodName Create `
            -Arguments @{ CommandLine = $cmd } -ErrorAction Stop

        if ([int]$create.ReturnValue -ne 0) {
            throw "Win32_Process.Create falhou. ReturnValue=$($create.ReturnValue)"
        }

        $pid = [int]$create.ProcessId
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false

        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 750
            $proc = Get-CimInstance -CimSession $session -ClassName Win32_Process -Filter "ProcessId = $pid" -ErrorAction SilentlyContinue
            if (-not $proc) { break }
        }

        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) { $timedOut = $true }

        return [pscustomobject]@{
            Success    = (-not $timedOut)
            ProcessId  = $pid
            TimedOut   = $timedOut
            CommandLine = $cmd
            Mensagem   = if ($timedOut) { "Remote process PID $pid is still running after $TimeoutSeconds seconds." } else { "Remote process PID $pid finished." }
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false; ProcessId=$null; TimedOut=$false; CommandLine=$CommandLine; Mensagem=$_.Exception.Message
        }
    }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
}

function Get-InstalledProgramsRemote {
    <#
        Adaptacao REMOTA do motor do "Uninstall String Tool.ps1".
        Nao usa SCCM Run Script, nao espera ScriptOutput/payload e nao usa WinRM.
        Le o registro da maquina teste diretamente via WMI/DCOM StdRegProv.
    #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Filter
    )

    $HKLM = [uint32]2147483650
    $HKU  = [uint32]2147483651
    $wanted = Get-NormalizedSoftwareName $Filter
    if ([string]::IsNullOrWhiteSpace($wanted)) { return @() }

    $session = $null
    try {
        $opt = New-CimSessionOption -Protocol Dcom
        $session = New-CimSession -ComputerName $ComputerName -SessionOption $opt -OperationTimeoutSec 12 -ErrorAction Stop

        $locations = @(
            [pscustomobject]@{ Hive=$HKLM; Base='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope='HKLM 64-bit' },
            [pscustomobject]@{ Hive=$HKLM; Base='SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope='HKLM 32-bit' }
        )

        # Replica o HKCU do Uninstall String Tool para todos os perfis atualmente carregados.
        foreach ($sid in @(Get-RemoteRegistrySubKeys -CimSession $session -Hive $HKU -SubKey '')) {
            if ($sid -match '^S-1-5-21-' -and $sid -notmatch '_Classes$') {
                $locations += [pscustomobject]@{
                    Hive=$HKU
                    Base="$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
                    Scope="HKU $sid"
                }
            }
        }

        $results = New-Object System.Collections.Generic.List[object]

        foreach ($loc in $locations) {
            foreach ($child in @(Get-RemoteRegistrySubKeys -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $loc.Base)) {
                $sub = "$($loc.Base)\$child"
                $displayName = Get-RemoteRegistryStringValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'DisplayName'
                if ([string]::IsNullOrWhiteSpace($displayName)) { continue }

                $actual = Get-NormalizedSoftwareName $displayName
                if ($actual -notlike "*$wanted*" -and $wanted -notlike "*$actual*") { continue }

                $obj = [pscustomobject]@{
                    DisplayName          = $displayName
                    DisplayVersion       = Get-RemoteRegistryStringValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'DisplayVersion'
                    Publisher            = Get-RemoteRegistryStringValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'Publisher'
                    InstallLocation      = Get-RemoteRegistryStringValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'InstallLocation'
                    UninstallString      = Get-RemoteRegistryStringValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'UninstallString'
                    QuietUninstallString = Get-RemoteRegistryStringValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'QuietUninstallString'
                    WindowsInstaller     = Get-RemoteRegistryDwordValue -CimSession $session -Hive ([uint32]$loc.Hive) -SubKey $sub -ValueName 'WindowsInstaller'
                    RegistryKeyName      = [string]$child
                    RegistrySubKey       = [string]$sub
                    RegistryHive         = if ([uint32]$loc.Hive -eq 2147483650) { 'HKLM' } else { 'HKU' }
                    RegistryView         = if ([string]$loc.Scope -eq 'HKLM 32-bit') { '32' } elseif ([string]$loc.Scope -eq 'HKLM 64-bit') { '64' } else { 'Default' }
                    RegistryPath         = "$($loc.Scope):\$sub"
                    Escopo               = [string]$loc.Scope
                }
                [void]$results.Add($obj)
            }
        }

        return @($results | Sort-Object DisplayName, DisplayVersion -Unique)
    }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
}

function Get-SilentUninstallSuggestion {
    param(
        [string]$UninstallString,
        [string]$QuietUninstallString,
        [string]$RegistryKeyName
    )

    if (-not [string]::IsNullOrWhiteSpace($QuietUninstallString)) {
        return $QuietUninstallString.Trim()
    }

    $us = if ($UninstallString) { $UninstallString.Trim() } else { '' }

    # MSI: primeiro tenta GUID na UninstallString; depois o nome da subchave.
    $guid = $null
    if ($us -match '(\{[0-9A-Fa-f-]{36}\})') { $guid = $Matches[1] }
    elseif ($RegistryKeyName -match '^\{[0-9A-Fa-f-]{36}\}$') { $guid = $RegistryKeyName }

    if (($us -match '(?i)msiexec') -and $guid) {
        return "msiexec.exe /x $guid /qn /norestart"
    }

    if ([string]::IsNullOrWhiteSpace($us)) { return $null }

    $knownSilent = @('/S','/silent','/verysilent','/qn','/quiet','-silent','--silent')
    foreach ($sw in $knownSilent) {
        if ($us -match [regex]::Escape($sw)) { return $us }
    }

    $exePath = $null
    if ($us -match '^\s*"([^"]+)"') { $exePath = $Matches[1] }
    elseif ($us -match '^\s*(\S+\.exe)') { $exePath = $Matches[1] }

    if (-not $exePath) { return $null }

    $exeName = [IO.Path]::GetFileName($exePath).ToLowerInvariant()
    switch -Regex ($exeName) {
        'unins\d*\.exe'  { return ('"' + $exePath + '" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART') }
        'uninstall\.exe' { return ('"' + $exePath + '" /S') }
        'setup\.exe'     { return ('"' + $exePath + '" /S') }
        default          { return $null } # nao inventa /S para um EXE desconhecido
    }
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
        [string]$WindowTitle = "Select the application detected in the test machine registry",
        [string[]]$ColumnHeaders = @("Name (DisplayName)", "Version", "Publisher")
    )

    $picker = New-Object System.Windows.Forms.Form
    $picker.Text = $WindowTitle
    $picker.Size = New-Object System.Drawing.Size(660, 460)
    $picker.StartPosition = 'CenterParent'
    $picker.FormBorderStyle = 'FixedDialog'
    $picker.MaximizeBox = $false
    $picker.MinimizeBox = $false

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "Filter by name:"
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
    $lblCount.Text = "$($Items.Count) program(s) found in total on this machine."
    $lblCount.ForeColor = 'Gray'
    $picker.Controls.Add($lblCount)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Select"
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

    $deploymentTypeName = "$AppName - Script Installer"

    try {
        if ([string]::IsNullOrWhiteSpace($DetectionScript)) {
            throw "The Detection Script is empty. The application will NOT be created."
        }

        New-CMApplication -Name $AppName -Publisher $Publisher -SoftwareVersion $Version -ErrorAction Stop | Out-Null

        Write-Log "[CREATE] Application created."
        Write-Log "[CREATE] Creating Deployment Type with Detection Method in one pass..."
        Write-Log "[CREATE] Detection script length: $($DetectionScript.Length) characters."

        Add-CMScriptDeploymentType `
            -ApplicationName $AppName `
            -DeploymentTypeName $deploymentTypeName `
            -ContentLocation $SourceFolder `
            -InstallCommand $InstallCommand `
            -UninstallCommand $UninstallCommand `
            -InstallationBehaviorType InstallForSystem `
            -LogonRequirementType WhetherOrNotUserLoggedOn `
            -UserInteractionMode Hidden `
            -ScriptLanguage PowerShell `
            -ScriptText $DetectionScript `
            -ErrorAction Stop | Out-Null

        Write-Log "[CREATE] Deployment Type + Detection Method created."
        Write-Log "[CREATE] COMPLETE."

        return [PSCustomObject]@{
            Success = $true
            Mensagem = "Application '$AppName' created with Deployment Type and PowerShell Detection Method configured in Configuration Manager."
        }
    }
    catch {
        return [PSCustomObject]@{ Success = $false; Mensagem = $_.Exception.Message }
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
$script:RegistryUninstallCommand = $null  # uninstall silencioso vindo do registro; source e fallback
$script:BuildId = '2026.08.26-SCCM-CREATOR-FINAL9-ONEPASS-DETECTION'

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
$grpConn.Text = "1. SCCM Connection"
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
$btnConnect.Text = "Connect"
$btnConnect.Location = New-Object System.Drawing.Point(500, 20)
$btnConnect.Size = New-Object System.Drawing.Size(90, 25)
$grpConn.Controls.Add($btnConnect)

$lblConnStatus = New-Object System.Windows.Forms.Label
$lblConnStatus.Text = "Not connected."
$lblConnStatus.ForeColor = 'Red'
$lblConnStatus.Location = New-Object System.Drawing.Point(10, 55)
$lblConnStatus.Size = New-Object System.Drawing.Size(650, 20)
$grpConn.Controls.Add($lblConnStatus)

# --- Grupo: Dados da Aplicacao ---
$grpApp = New-Object System.Windows.Forms.GroupBox
$grpApp.Text = "2. Application Details"
$grpApp.Location = New-Object System.Drawing.Point(10, 110)
$grpApp.Size = New-Object System.Drawing.Size(690, 240)
$form.Controls.Add($grpApp)

$lblAppName = New-Object System.Windows.Forms.Label
$lblAppName.Text = "Application Name:"
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
        $script:RegistryUninstallCommand = $null
        $script:DetectionText = $null
        $txtVersion.Text = ''
        $txtDetectPattern.Text = ''
        if ($lblDetectionMode) {
            $lblDetectionMode.Text = 'Detection has not been generated for this name yet.'
            $lblDetectionMode.ForeColor = 'Gray'
        }
    }
})

$txtAppName.Add_TextChanged({
    if ($script:DetectionMode -eq 'Registry') {
        $script:DetectedRegistryApp = $null
        $script:RegistryUninstallCommand = $null
        $script:DetectionText = $null
        $txtDetectPattern.Text = ''
        $txtVersion.Text = ''
        $lblDetectionMode.Text = "Detection mode: waiting for discovery by Application Name."
        $lblDetectionMode.ForeColor = 'Gray'
    }
})

$lblPublisher = New-Object System.Windows.Forms.Label
$lblPublisher.Text = "Publisher:"
$lblPublisher.Location = New-Object System.Drawing.Point(10, 55)
$lblPublisher.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblPublisher)

$txtPublisher = New-Object System.Windows.Forms.TextBox
$txtPublisher.Location = New-Object System.Drawing.Point(140, 52)
$txtPublisher.Size = New-Object System.Drawing.Size(350, 20)
$grpApp.Controls.Add($txtPublisher)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "Version detectada:"
$lblVersion.Location = New-Object System.Drawing.Point(10, 85)
$lblVersion.Size = New-Object System.Drawing.Size(120, 20)
$grpApp.Controls.Add($lblVersion)

$txtVersion = New-Object System.Windows.Forms.TextBox
$txtVersion.Location = New-Object System.Drawing.Point(140, 82)
$txtVersion.Size = New-Object System.Drawing.Size(150, 20)
$grpApp.Controls.Add($txtVersion)

$lblDetectPattern = New-Object System.Windows.Forms.Label
$lblDetectPattern.Text = "Detected DisplayName:"
$lblDetectPattern.Location = New-Object System.Drawing.Point(300, 85)
$lblDetectPattern.Size = New-Object System.Drawing.Size(190, 20)
$grpApp.Controls.Add($lblDetectPattern)

$txtDetectPattern = New-Object System.Windows.Forms.TextBox
$txtDetectPattern.Location = New-Object System.Drawing.Point(495, 82)
$txtDetectPattern.Size = New-Object System.Drawing.Size(190, 20)
$grpApp.Controls.Add($txtDetectPattern)

$lblSourceFolder = New-Object System.Windows.Forms.Label
$lblSourceFolder.Text = "Source Folder:"
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
        $lblScanResult.Text = 'Folder changed - scan again.'
    }
})


$btnPasteFolder = New-Object System.Windows.Forms.Button
$btnPasteFolder.Text = "Paste"
$btnPasteFolder.Location = New-Object System.Drawing.Point(140, 138)
$btnPasteFolder.Size = New-Object System.Drawing.Size(60, 23)
$grpApp.Controls.Add($btnPasteFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Browse..."
$btnBrowse.Location = New-Object System.Drawing.Point(205, 138)
$btnBrowse.Size = New-Object System.Drawing.Size(80, 23)
$grpApp.Controls.Add($btnBrowse)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = "Scan Folder"
$btnScan.Location = New-Object System.Drawing.Point(290, 138)
$btnScan.Size = New-Object System.Drawing.Size(120, 23)
$grpApp.Controls.Add($btnScan)

$btnUseInteractiveSession = New-Object System.Windows.Forms.Button
$btnUseInteractiveSession.Text = "Use logged-on session (no password)"
$btnUseInteractiveSession.Location = New-Object System.Drawing.Point(140, 165)
$btnUseInteractiveSession.Size = New-Object System.Drawing.Size(220, 23)
$grpApp.Controls.Add($btnUseInteractiveSession)

$btnSourceCred = New-Object System.Windows.Forms.Button
$btnSourceCred.Text = "Or provide credentials..."
$btnSourceCred.Location = New-Object System.Drawing.Point(365, 165)
$btnSourceCred.Size = New-Object System.Drawing.Size(150, 23)
$grpApp.Controls.Add($btnSourceCred)

$btnClearSourceCred = New-Object System.Windows.Forms.Button
$btnClearSourceCred.Text = "Clear"
$btnClearSourceCred.Location = New-Object System.Drawing.Point(520, 165)
$btnClearSourceCred.Size = New-Object System.Drawing.Size(55, 23)
$grpApp.Controls.Add($btnClearSourceCred)

$lblSourceCredStatus = New-Object System.Windows.Forms.Label
$lblSourceCredStatus.Text = "Folder access: using the current script account."
$lblSourceCredStatus.ForeColor = 'Gray'
$lblSourceCredStatus.Location = New-Object System.Drawing.Point(10, 192)
$lblSourceCredStatus.Size = New-Object System.Drawing.Size(670, 18)
$grpApp.Controls.Add($lblSourceCredStatus)

$lblScanResult = New-Object System.Windows.Forms.Label
$lblScanResult.Text = "Installation: -- | Uninstallation: --"
$lblScanResult.Location = New-Object System.Drawing.Point(10, 210)
$lblScanResult.Size = New-Object System.Drawing.Size(670, 20)
$grpApp.Controls.Add($lblScanResult)

# --- Grupo: Maquina de Teste Remota (CyberArk / conta de servico sem acesso a maquina teste) ---
$grpRemote = New-Object System.Windows.Forms.GroupBox
$grpRemote.Text = "3. Test Machine (Remote - optional, use when the script runs on the server)"
$grpRemote.Location = New-Object System.Drawing.Point(10, 360)
$grpRemote.Size = New-Object System.Drawing.Size(690, 125)
$form.Controls.Add($grpRemote)

$lblTestMachine = New-Object System.Windows.Forms.Label
$lblTestMachine.Text = "Test Machine Name/IP:"
$lblTestMachine.Location = New-Object System.Drawing.Point(10, 25)
$lblTestMachine.Size = New-Object System.Drawing.Size(150, 20)
$grpRemote.Controls.Add($lblTestMachine)

$txtTestMachine = New-Object System.Windows.Forms.TextBox
$txtTestMachine.Location = New-Object System.Drawing.Point(165, 22)
$txtTestMachine.Size = New-Object System.Drawing.Size(200, 20)
$grpRemote.Controls.Add($txtTestMachine)

$btnConnectRemote = New-Object System.Windows.Forms.Button
$btnConnectRemote.Text = "Connect via SCCM / SYSTEM"
$btnConnectRemote.Location = New-Object System.Drawing.Point(375, 21)
$btnConnectRemote.Size = New-Object System.Drawing.Size(170, 23)
$grpRemote.Controls.Add($btnConnectRemote)

$btnDisconnectRemote = New-Object System.Windows.Forms.Button
$btnDisconnectRemote.Text = "Disconnect"
$btnDisconnectRemote.Location = New-Object System.Drawing.Point(555, 21)
$btnDisconnectRemote.Size = New-Object System.Drawing.Size(125, 23)
$grpRemote.Controls.Add($btnDisconnectRemote)

$lblRemoteStatus = New-Object System.Windows.Forms.Label
$lblRemoteStatus.Text = "No test machine connected through SCCM (tests will run locally)."
$lblRemoteStatus.ForeColor = 'Gray'
$lblRemoteStatus.Location = New-Object System.Drawing.Point(10, 48)
$lblRemoteStatus.Size = New-Object System.Drawing.Size(670, 18)
$grpRemote.Controls.Add($lblRemoteStatus)

$btnDetectRegistry = New-Object System.Windows.Forms.Button
$btnDetectRegistry.Text = "Generate Detection by Application Name"
$btnDetectRegistry.Location = New-Object System.Drawing.Point(10, 70)
$btnDetectRegistry.Size = New-Object System.Drawing.Size(280, 25)
$btnDetectRegistry.BackColor = [System.Drawing.Color]::LightSteelBlue
$grpRemote.Controls.Add($btnDetectRegistry)

$btnDetectFile = New-Object System.Windows.Forms.Button
$btnDetectFile.Text = "Detect by File/Executable..."
$btnDetectFile.Location = New-Object System.Drawing.Point(300, 70)
$btnDetectFile.Size = New-Object System.Drawing.Size(230, 25)
$btnDetectFile.BackColor = [System.Drawing.Color]::LightGoldenrodYellow
$grpRemote.Controls.Add($btnDetectFile)

$btnClearFileDetection = New-Object System.Windows.Forms.Button
$btnClearFileDetection.Text = "Back to Automatic Registry"
$btnClearFileDetection.Location = New-Object System.Drawing.Point(540, 70)
$btnClearFileDetection.Size = New-Object System.Drawing.Size(140, 25)
$grpRemote.Controls.Add($btnClearFileDetection)

$lblDetectionMode = New-Object System.Windows.Forms.Label
$lblDetectionMode.Text = "Detection mode: automatic Registry by Application Name."
$lblDetectionMode.ForeColor = 'Gray'
$lblDetectionMode.Location = New-Object System.Drawing.Point(10, 98)
$lblDetectionMode.Size = New-Object System.Drawing.Size(670, 18)
$grpRemote.Controls.Add($lblDetectionMode)

# --- Grupo: Comandos gerados ---
$grpCmds = New-Object System.Windows.Forms.GroupBox
$grpCmds.Text = "4. Generated Commands (SCCM Deployment Type)"
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

# --- Grupo: Detection e Criacao ---
$grpTest = New-Object System.Windows.Forms.GroupBox
$grpTest.Text = "5. Detection and Application Creation"
$grpTest.Location = New-Object System.Drawing.Point(10, 635)
$grpTest.Size = New-Object System.Drawing.Size(690, 60)
$form.Controls.Add($grpTest)

$btnTestDetection = New-Object System.Windows.Forms.Button
$btnTestDetection.Text = "Test Detection"
$btnTestDetection.Location = New-Object System.Drawing.Point(10, 22)
$btnTestDetection.Size = New-Object System.Drawing.Size(180, 25)
$grpTest.Controls.Add($btnTestDetection)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text = "CREATE APPLICATION IN SCCM"
$btnCreate.Location = New-Object System.Drawing.Point(205, 20)
$btnCreate.Size = New-Object System.Drawing.Size(475, 30)
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
        [System.Windows.Forms.MessageBox]::Show("Enter the Site Server and Site Code.", "Warning") | Out-Null
        return
    }
    Write-Log "Conectando a $($txtServer.Text) ($($txtSiteCode.Text))..."
    $result = Connect-ToSCCM -SiteServer $txtServer.Text -SiteCode $txtSiteCode.Text
    if ($result.Success) {
        $script:SiteServer = $txtServer.Text.Trim()
        $script:SiteCode   = $txtSiteCode.Text.Trim()
        $lblConnStatus.Text = $result.Mensagem
        $lblConnStatus.ForeColor = 'Green'
    } else {
        $lblConnStatus.Text = "Failed: $($result.Mensagem)"
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
                Write-Log "Pasted path was cleaned automatically (quotes/spaces removed)."
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("The clipboard does not contain text.", "Warning") | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to read the clipboard. This usually happens when the script is running as Administrator " +
            "e o texto foi copiado por um programa sem elevacao (bloqueio de UIPI do Windows).`n`n" +
            "Solution: run the script WITHOUT 'Run as Administrator' (the SCCM connection does not require elevation), " +
            "or type the path manually in the field.",
            "Paste Error",
            'OK', 'Warning'
        ) | Out-Null
    }
})

$btnBrowse.Add_Click({
    # FolderBrowserDialog classico nao permite digitar/colar caminhos UNC (\\servidor\pasta).
    # Truque: usar OpenFileDialog (que tem barra de endereco completa e aceita UNC) para
    # navegar/digitar ate a pasta desejada e depois pegar so o diretorio.
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Browse to the source folder (or paste/type the UNC path in the 'File name' box) and click Open"
    $dlg.CheckFileExists = $false
    $dlg.CheckPathExists = $true
    $dlg.ValidateNames = $false
    $dlg.Multiselect = $false
    $dlg.FileName = "Select this folder"
    $dlg.Filter = "Folders|*.folder"

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
    elseif ($Acesso -and $Acesso.Success) {
        $script:EffectiveSourcePath = $Acesso.CaminhoEfetivo
        Write-Log $Acesso.Mensagem
        $script:InstallInfo = Get-InstallCommandLine -FolderPath $script:EffectiveSourcePath -Action 'install'
        $script:UninstallInfo = Get-InstallCommandLine -FolderPath $script:EffectiveSourcePath -Action 'uninstall'
    }
    else {
        throw 'Complete-FolderScan recebeu um estado de acesso invalido.'
    }

    $installStatus = if ($script:InstallInfo.Encontrado) { "$($script:InstallInfo.Tipo) ($($script:InstallInfo.Arquivo))" } else { 'NOT FOUND' }
    $uninstallStatus = if ($script:UninstallInfo.Encontrado) { "$($script:UninstallInfo.Tipo) ($($script:UninstallInfo.Arquivo))" } else { 'NOT FOUND' }
    $lblScanResult.Text = "Installation: $installStatus | Uninstallation: $uninstallStatus"
    $txtInstallCmd.Text = if ($script:InstallInfo.Encontrado) { $script:InstallInfo.Comando } else { '' }
    $txtUninstallCmd.Text = if ($script:UninstallInfo.Encontrado) { $script:UninstallInfo.Comando } else { '' }

    Write-Log "SOURCE ORIGINAL FIXADO: $($script:OriginalSourcePath)"
    if ($script:InstallInfo.Encontrado -and $script:UninstallInfo.Encontrado) {
        Write-Log "Scripts found. Install: $($script:InstallInfo.Comando) | Uninstall: $($script:UninstallInfo.Comando)"
    } else {
        Write-Log 'WARNING: both install and uninstall files were not found in the source folder root.'
    }
}


$btnUseInteractiveSession.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Enter the source folder first.', 'Warning') | Out-Null
        return
    }

    $caminhoLimpo = Get-CleanPath -Path $txtSourceFolder.Text
    $txtSourceFolder.Text = $caminhoLimpo
    Write-Log "Reading the folder through the logged-on Windows session without copying the package: $caminhoLimpo"
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { $manifest = Get-SourceManifestViaInteractiveSession -SourcePath $caminhoLimpo }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }

    if (-not $manifest.Success) {
        Write-Log "Failed to read folder through interactive session: $($manifest.Mensagem)"
        [System.Windows.Forms.MessageBox]::Show($manifest.Mensagem, 'Folder Read Failed', 'OK', 'Warning') | Out-Null
        return
    }

    $lblSourceCredStatus.Text = 'Folder access: reading through the logged-on Windows session (no copy).'
    $lblSourceCredStatus.ForeColor = 'Green'
    Complete-FolderScan -CaminhoOriginal $caminhoLimpo -Manifest $manifest
})


$btnSourceCred.Add_Click({
    $cred = Get-Credential -Message "Credentials with READ access to the source folder (for example, your personal account if the account running this script, such as an SCCM service account, cannot access the share)"
    if (-not $cred) { return }
    $script:SourceCredential = $cred
    $lblSourceCredStatus.Text = "Folder access: using provided credentials ($($cred.UserName))."
    $lblSourceCredStatus.ForeColor = 'Green'
    Write-Log "Alternate credentials set for source folder access ($($cred.UserName))."
})

$btnClearSourceCred.Add_Click({
    $script:SourceCredential = $null
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }
    $lblSourceCredStatus.Text = "Folder access: using the current script account."
    $lblSourceCredStatus.ForeColor = 'Gray'
    Write-Log "Alternate credentials removed. Returning to the current script account."
})

$btnScan.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Enter the source folder.", "Warning") | Out-Null
        return
    }

    # Sempre normaliza o texto do campo antes de validar (remove aspas/espacos
    # que podem ter vindo de copia da barra de enderecos do Explorer).
    $caminhoOriginal = $txtSourceFolder.Text
    $caminhoLimpo    = Get-CleanPath -Path $caminhoOriginal
    if ($caminhoOriginal -ne $caminhoLimpo) {
        $txtSourceFolder.Text = $caminhoLimpo
        Write-Log "Path normalized before validation: '$caminhoLimpo'"
    }

    if ($script:SourceCredential) {
        Write-Log "Testing folder access with alternate credentials ($($script:SourceCredential.UserName))..."
    } else {
        Write-Log "Testing folder access with the current script account..."
    }

    $acesso = Resolve-SourceAccess -Path $caminhoLimpo -Credential $script:SourceCredential

    if (-not $acesso.Success) {
        Write-Log "Failed to access folder: $($acesso.Mensagem)"
        Write-Log "Tested path: [`"$caminhoLimpo`"] (length: $($caminhoLimpo.Length) characters)"
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to access this path:`n`n$caminhoLimpo`n`n" +
            "Detalhe: $($acesso.Mensagem)`n`n" +
            "If you do not have credentials to enter, use the " +
            "'Use logged-on session (no password)' em vez deste.",
            "Unable to access folder",
            'OK', 'Warning'
        ) | Out-Null
        return
    }

    Complete-FolderScan -CaminhoOriginal $caminhoLimpo -Acesso $acesso
})

$btnConnectRemote.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtTestMachine.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Enter the test machine name.", "Warning") | Out-Null
        return
    }
    if (-not $script:SiteServer -or -not $script:SiteCode) {
        [System.Windows.Forms.MessageBox]::Show("Connect to SCCM first in section 1.", "Warning") | Out-Null
        return
    }

    $computer = $txtTestMachine.Text.Trim()
    $btnConnectRemote.Enabled = $false
    $lblRemoteStatus.Text = "Validando $computer pelo SCCM..."
    $lblRemoteStatus.ForeColor = 'DarkOrange'
    [System.Windows.Forms.Application]::DoEvents()

    Write-Log "Validating test machine $computer through SCCM Run Script (no WinRM/no workstation credentials)..."
    $result = Connect-RemoteTestMachine -ComputerName $computer

    if ($result.Success) {
        $script:RemoteTestConnected = $true
        $script:RemoteTestComputer  = $computer
        $lblRemoteStatus.Text = "Conectado via SCCM: $computer - execucao remota como SYSTEM."
        $lblRemoteStatus.ForeColor = 'Green'
    }
    else {
        $script:RemoteTestConnected = $false
        $script:RemoteTestComputer  = $null
        $lblRemoteStatus.Text = "SCCM failure: $($result.Mensagem)"
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
    $lblRemoteStatus.Text = "No test machine connected through SCCM (tests will run locally)."
    $lblRemoteStatus.ForeColor = 'Gray'
    Write-Log "Test machine disconnected from the App Creator logical session. No PSSession/WinRM was used."
})

$btnDetectRegistry.Add_Click({
    if (-not $script:RemoteTestConnected -or -not $script:RemoteTestComputer) {
        [System.Windows.Forms.MessageBox]::Show("Connect to the test machine first using the 'Connect via SCCM / SYSTEM' button above.", "Warning") | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($txtAppName.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Enter only the Application Name. The version will be discovered automatically from the test machine registry.", "Warning") | Out-Null
        return
    }

    $appSearchName = $txtAppName.Text.Trim()
    Write-Log "[REGISTRY DIRECT] Searching for '$appSearchName' directly in the registry of $($script:RemoteTestComputer) via WMI/DCOM. NO Run Script, NO payload."
    $btnDetectRegistry.Enabled = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $programs = @()
    $erro = $null
    try {
        $programs = @(Get-InstalledProgramsRemote -ComputerName $script:RemoteTestComputer -Filter $appSearchName)
    }
    catch { $erro = $_.Exception.Message }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnDetectRegistry.Enabled = $true
    }

    if ($erro) {
        Write-Log "[REGISTRY DIRECT] ERROR: $erro"
        [System.Windows.Forms.MessageBox]::Show(
            "Unable to read the remote registry of $($script:RemoteTestComputer).`n`n$erro`n`n" +
            "This query uses WMI/DCOM StdRegProv and does NOT use Run Script/payload.",
            "Remote Registry Query Error", 'OK', 'Error') | Out-Null
        return
    }

    Write-Log "[REGISTRY DIRECT] $($programs.Count) correspondencia(s) encontrada(s) para '$appSearchName'."

    $selecionado = Resolve-InstalledSoftwareByApplicationName -Items @($programs) -ApplicationName $appSearchName
    if (-not $selecionado) {
        $script:DetectedRegistryApp = $null
        $script:RegistryUninstallCommand = $null
        Write-Log "[REGISTRY DIRECT] No valid entry with DisplayName/DisplayVersion was found."
        [System.Windows.Forms.MessageBox]::Show(
            "Could not find '$appSearchName' in the test machine registry.`n`n" +
            "Foram verificadas HKLM 64-bit, WOW6432Node e as hives de usuario carregadas diretamente via WMI/DCOM.",
            "Application Not Found", 'OK', 'Warning') | Out-Null
        return
    }

    $script:DetectedRegistryApp = $selecionado
    $txtDetectPattern.Text = [string]$selecionado.DisplayName
    $txtVersion.Text = [string]$selecionado.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($txtPublisher.Text) -and -not [string]::IsNullOrWhiteSpace([string]$selecionado.Publisher)) {
        $txtPublisher.Text = [string]$selecionado.Publisher
    }

    $script:RegistryUninstallCommand = Get-SilentUninstallSuggestion `
        -UninstallString ([string]$selecionado.UninstallString) `
        -QuietUninstallString ([string]$selecionado.QuietUninstallString) `
        -RegistryKeyName ([string]$selecionado.RegistryKeyName)

    # A linha de uninstall descoberta no registro e somente informativa.
    # O Deployment Type deve executar o wrapper uninstall.bat/uninstall.ps1 da source,
    # pois esse wrapper contem a logica operacional ja validada (timeout/exit codes).
    $txtUninstallCmd.Text = if ($script:UninstallInfo -and $script:UninstallInfo.Encontrado) { $script:UninstallInfo.Comando } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($script:RegistryUninstallCommand)) {
        Write-Log "[REGISTRY DIRECT] Registry uninstall command found (informational only; it will NOT be used by the Deployment Type): $($script:RegistryUninstallCommand)"
    } else {
        Write-Log "[REGISTRY DIRECT] No additional silent uninstall command was found in the registry. The source wrapper will be used."
    }

    $script:DetectionMode = 'Registry'
    $script:DetectionFilePath = $null
    $lblDetectionMode.Text = "DIRECT REGISTRY: $($selecionado.DisplayName) >= $($selecionado.DisplayVersion)"
    $lblDetectionMode.ForeColor = 'DarkGreen'
    $script:DetectionText = New-DetectionScriptText -DisplayNamePattern ([string]$selecionado.DisplayName) -MinVersion ([string]$selecionado.DisplayVersion)

    Write-Log "[REGISTRY DIRECT] FOUND: DisplayName='$($selecionado.DisplayName)' | DisplayVersion='$($selecionado.DisplayVersion)' | Publisher='$($selecionado.Publisher)' | Scope='$($selecionado.Escopo)'"
    Write-Log "[REGISTRY DIRECT] EXACT DETECTION KEY: $($selecionado.RegistryPath)"
    Write-Log "[REGISTRY DIRECT] UninstallString='$($selecionado.UninstallString)'"
    if ($selecionado.QuietUninstallString) { Write-Log "[REGISTRY DIRECT] QuietUninstallString='$($selecionado.QuietUninstallString)'" }

    $uninstallShow = if ($script:RegistryUninstallCommand) { $script:RegistryUninstallCommand } else { '(fallback: uninstall from source folder)' }
    [System.Windows.Forms.MessageBox]::Show(
        "Application found directly in the remote registry.`n`n" +
        "DisplayName: $($selecionado.DisplayName)`n" +
        "Version: $($selecionado.DisplayVersion)`n" +
        "Escopo: $($selecionado.Escopo)`n" +
        "Registry uninstall command (informational): $uninstallShow`n" +
        "Deployment Type usara: $($script:UninstallInfo.Comando)`n`n" +
        "No Run Script or payload was used.",
        "Automatic Detection Completed", 'OK', 'Information') | Out-Null
})

$btnDetectFile.Add_Click({
    if (-not $script:RemoteTestConnected -or -not $script:RemoteTestComputer) {
        [System.Windows.Forms.MessageBox]::Show("Connect to the test machine first using the 'Connect via SCCM / SYSTEM' button above.", "Warning") | Out-Null
        return
    }

    $sugestaoNome = if (-not [string]::IsNullOrWhiteSpace($txtAppName.Text)) {
        "*" + ($txtAppName.Text -replace '\s', '') + "*.exe"
    } else { "*.exe" }

    $pattern = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Executable file name pattern to search for (wildcard * supported).`n`n" +
        "The default search covers Program Files, Program Files (x86), and ProgramData.`n" +
        "Use this when the app does NOT appear in the registry or other detection sources. " +
        "default folders - for example, installers that do not register anything in Windows.",
        "Search executable on test machine",
        $sugestaoNome
    )
    if ([string]::IsNullOrWhiteSpace($pattern)) { return }

    $extraRoots = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Additional folders to search as well (optional), separated by semicolons.`n" +
        "Exemplo: D:\Apps;C:\CapTalk`n`n" +
        "Leave blank to search only the default folders.",
        "Additional Folders (optional)",
        ""
    )

    Write-Log "Searching for '$pattern' on $($script:RemoteTestComputer) (Program Files, Program Files (x86), ProgramData$(if ($extraRoots) { ' + extra folders: ' + $extraRoots }))... this may take a few minutes."
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
        Write-Log "File search error: $erro"
        [System.Windows.Forms.MessageBox]::Show($erro, "File Search Error", 'OK', 'Error') | Out-Null
        return
    }

    $raw = $status.ScriptOutput
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "No file found matching pattern '$pattern' in the searched folders."
        [System.Windows.Forms.MessageBox]::Show(
            "No file found matching pattern '$pattern' in Program Files / Program Files (x86) / ProgramData" +
            $(if ($extraRoots) { " nem em: $extraRoots" } else { "" }) + ".`n`n" +
            "Try a broader pattern (for example, '*.exe' without a prefix) or provide an additional folder where the app is installed.",
            "No Results",
            'OK', 'Warning'
        ) | Out-Null
        return
    }

    try {
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to parse file search response: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Invalid response from the test machine.`n`n$raw", "Error", 'OK', 'Error') | Out-Null
        return
    }

    if ($json -isnot [System.Array]) { $json = @($json) }

    if ($json.Count -eq 0) {
        Write-Log "No file found matching pattern '$pattern'."
        [System.Windows.Forms.MessageBox]::Show("No file found matching pattern '$pattern'.", "Warning") | Out-Null
        return
    }

    Write-Log "Found $($json.Count) file(s) matching pattern '$pattern'. Opening selection list..."

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
        -WindowTitle "Select the executable found on the test machine" `
        -ColumnHeaders @("Full Path", "File Version", "Modified")

    if (-not $selecionado) {
        Write-Log "File selection canceled by the user."
        return
    }

    $script:DetectionMode     = 'File'
    $script:DetectionFilePath = $selecionado.DisplayName  # aqui guardamos o FullName do arquivo

    if (-not [string]::IsNullOrWhiteSpace($selecionado.DisplayVersion)) {
        $txtVersion.Text = $selecionado.DisplayVersion
    }

    $lblDetectionMode.Text = "Detection mode: FILE -> $($script:DetectionFilePath)"
    $lblDetectionMode.ForeColor = 'DarkGoldenrod'

    Write-Log "FILE detection selected: '$($script:DetectionFilePath)' (file version: $($selecionado.DisplayVersion))"

    [System.Windows.Forms.MessageBox]::Show(
        "Detection will use the EXISTENCE of this executable (and its file version, if available):`n`n" +
        "$($script:DetectionFilePath)`n`n" +
        "This replaces registry detection for this application. To return to registry detection, " +
        "click 'Back to Automatic Registry'.",
        "File Detection Selected",
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
    $lblDetectionMode.Text = "Detection mode: automatic Registry by Application Name."
    $lblDetectionMode.ForeColor = 'Gray'
    Write-Log "Detection mode returned to automatic Registry by Application Name."
})

function Build-CurrentDetectionText {
    <#
        Registry: usa EXCLUSIVAMENTE a entrada que foi descoberta na maquina
        teste a partir do Nome da Aplicacao. O campo Version e apenas o reflexo
        da DisplayVersion encontrada; ele nao e criterio de descoberta.
    #>
    if ($script:DetectionMode -eq 'File' -and $script:DetectionFilePath) {
        return New-FileDetectionScriptText -FilePath $script:DetectionFilePath -MinVersion $txtVersion.Text
    }

    if (-not $script:DetectedRegistryApp) {
        [System.Windows.Forms.MessageBox]::Show(
            "First click 'Generate Detection by Application Name'.`n`nThe tool needs to query the test machine and discover the actual DisplayName/DisplayVersion in the registry.",
            "Detection Not Generated Yet", 'OK', 'Warning') | Out-Null
        return $null
    }

    $realName = [string]$script:DetectedRegistryApp.DisplayName
    $realVersion = [string]$script:DetectedRegistryApp.DisplayVersion
    if ([string]::IsNullOrWhiteSpace($realName) -or [string]::IsNullOrWhiteSpace($realVersion)) { return $null }

    # Reafirma os valores descobertos para evitar que uma digitacao manual
    # posterior altere silenciosamente o Detection Method.
    $txtDetectPattern.Text = $realName
    $txtVersion.Text = $realVersion
    if ($script:DetectedRegistryApp.RegistrySubKey -and $script:DetectedRegistryApp.RegistryHive) {
        return New-ExactRegistryDetectionScriptText `
            -DisplayName $realName `
            -MinVersion $realVersion `
            -RegistrySubKey ([string]$script:DetectedRegistryApp.RegistrySubKey) `
            -RegistryHive ([string]$script:DetectedRegistryApp.RegistryHive) `
            -RegistryView ([string]$script:DetectedRegistryApp.RegistryView)
    }
    return New-DetectionScriptText -DisplayNamePattern $realName -MinVersion $realVersion
}

function Convert-AppVersionObject {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '\d+(?:\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    try { return [version]::new($parts[0],$parts[1],$parts[2],$parts[3]) } catch { return $null }
}

$btnTestDetection.Add_Click({
    try {
        if ($script:RemoteTestConnected -and $script:RemoteTestComputer) {
            if ($script:DetectionMode -eq 'File' -and $script:DetectionFilePath) {
                # Mantem o fluxo de arquivo existente; esta correcao e especifica
                # para deteccao por REGISTRO, que nao deve usar Run Script/payload.
                Write-Log "Testing FILE detection on $($script:RemoteTestComputer)."
                $raw = Invoke-RemoteDetection -ComputerName $script:RemoteTestComputer -FilePath $script:DetectionFilePath -MinVersion $txtVersion.Text
                $obj = $null
                try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop } catch {}
                if ($obj -and $obj.Result -eq 'Installed') {
                    Write-Log "RESULT: Installed (file detection OK)"
                    [System.Windows.Forms.MessageBox]::Show("DETECTED`n`nFile: $($script:DetectionFilePath)`nMinimum version: $($txtVersion.Text)","Detection Test",'OK','Information') | Out-Null
                } else {
                    Write-Log "RESULT: Not detected by file."
                    [System.Windows.Forms.MessageBox]::Show("NOT DETECTED`n`nFile: $($script:DetectionFilePath)","Detection Test",'OK','Warning') | Out-Null
                }
                return
            }

            if (-not $script:DetectedRegistryApp) {
                [System.Windows.Forms.MessageBox]::Show("Generate detection automatically by Application Name first.", "Warning") | Out-Null
                return
            }

            $realName    = [string]$script:DetectedRegistryApp.DisplayName
            $realVersion = [string]$script:DetectedRegistryApp.DisplayVersion

            Write-Log "[DETECTION DIRECT] Testing registry directly on $($script:RemoteTestComputer). NO Run Script, NO payload."
            Write-Log "[DETECTION DIRECT] Expected: DisplayName='$realName' | version >= '$realVersion'"

            $matches = @(Get-InstalledProgramsRemote -ComputerName $script:RemoteTestComputer -Filter $realName)
            $expectedNorm = Get-NormalizedSoftwareName $realName
            $expectedVer  = Convert-AppVersionObject $realVersion

            $best = $null
            foreach ($m in $matches) {
                if ((Get-NormalizedSoftwareName ([string]$m.DisplayName)) -ne $expectedNorm) { continue }
                $iv = Convert-AppVersionObject ([string]$m.DisplayVersion)
                if (-not $iv) { continue }
                if (-not $best -or $iv -gt $best.VersionObject) {
                    $best = [pscustomobject]@{ Item=$m; VersionObject=$iv }
                }
            }

            $detected = $false
            if ($best -and $expectedVer -and $best.VersionObject -ge $expectedVer) { $detected = $true }

            if ($detected) {
                $found = $best.Item
                Write-Log "[DETECTION DIRECT] RESULT: DETECTED | DisplayName='$($found.DisplayName)' | DisplayVersion='$($found.DisplayVersion)' | Scope='$($found.Escopo)'"
                [System.Windows.Forms.MessageBox]::Show(
                    "DETECTED`n`nApplication: $($found.DisplayName)`nVersion instalada: $($found.DisplayVersion)`nMinimum version: $realVersion`nRegistry: $($found.Escopo)`n`nMethod: Direct remote Registry (no Run Script/payload).",
                    "Detection Test - OK", 'OK', 'Information') | Out-Null
            }
            else {
                $foundText = if ($best) { "$($best.Item.DisplayName) $($best.Item.DisplayVersion)" } elseif ($matches.Count -gt 0) { ($matches | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join "`n" } else { 'No matching entry found.' }
                Write-Log "[DETECTION DIRECT] RESULT: NOT DETECTED. Found: $foundText"
                [System.Windows.Forms.MessageBox]::Show(
                    "NOT DETECTED`n`nExpected: $realName >= $realVersion`n`nFound:`n$foundText`n`nMethod: Direct remote Registry (no Run Script/payload).",
                    "Detection Test", 'OK', 'Warning') | Out-Null
            }
        }
        else {
            $script:DetectionText = Build-CurrentDetectionText
            if (-not $script:DetectionText) { return }
            Write-Log "No test machine connected - running the Detection script LOCALLY on this computer ($env:COMPUTERNAME)."
            $resultado = Invoke-Expression $script:DetectionText
            if (($resultado | Out-String).Trim() -eq 'Installed') {
                Write-Log "RESULT: Installed (detection OK)"
                [System.Windows.Forms.MessageBox]::Show("DETECTED locally.","Detection Test",'OK','Information') | Out-Null
            } else {
                Write-Log "RESULT: Not detected. Return: $(($resultado | Out-String).Trim())"
                [System.Windows.Forms.MessageBox]::Show("NOT DETECTED locally.","Detection Test",'OK','Warning') | Out-Null
            }
        }
    }
    catch {
        Write-Log "Detection execution error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Detection test error:`n`n$($_.Exception.Message)","Error",'OK','Error') | Out-Null
    }
})

$btnCreate.Add_Click({
    if ([string]::IsNullOrWhiteSpace($txtAppName.Text) -or [string]::IsNullOrWhiteSpace($txtSourceFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Enter Application Name and Source Folder.", "Warning") | Out-Null
        return
    }
    if ($script:DetectionMode -eq 'Registry' -and -not $script:DetectedRegistryApp) {
        [System.Windows.Forms.MessageBox]::Show("Before creating the application, click 'Generate Detection by Application Name' to discover the actual version in the test machine registry.", "Warning") | Out-Null
        return
    }
    if (-not $script:InstallInfo -or -not $script:InstallInfo.Encontrado -or
        -not $script:UninstallInfo -or -not $script:UninstallInfo.Encontrado -or
        -not $script:OriginalSourcePath) {
        [System.Windows.Forms.MessageBox]::Show("Scan the folder and confirm that install/uninstall files were found.", "Warning") | Out-Null
        return
    }

    $sourceNow = Get-CleanPath -Path $txtSourceFolder.Text
    if ($sourceNow -ne $script:OriginalSourcePath) {
        [System.Windows.Forms.MessageBox]::Show("The Source Folder changed after the last scan. Scan it again before creating the application.", "Source Changed", 'OK', 'Warning') | Out-Null
        return
    }

    $script:DetectionText = Build-CurrentDetectionText
    if (-not $script:DetectionText) { return }

    $descricaoDetection = if ($script:DetectionMode -eq 'File') {
        "File: $($script:DetectionFilePath)"
    } else {
        "EXACT Registry: $($script:DetectedRegistryApp.RegistryPath) | DisplayName='$($script:DetectedRegistryApp.DisplayName)' | DisplayVersion >= $($script:DetectedRegistryApp.DisplayVersion)"
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Confirm creation of application '$($txtAppName.Text)' in SCCM?`n`n" +
        "Content Location (actual UNC used by SCCM):`n$($script:OriginalSourcePath)`n`n" +
        "Detection method: $descricaoDetection`n`n" +
        "Install command: $($script:InstallInfo.Comando)`n" +
        "Uninstall command: $($script:UninstallInfo.Comando)",
        "Confirm",
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )
    if ($confirm -ne 'Yes') { return }

    Write-Log "Creating application '$($txtAppName.Text)' in SCCM (ContentLocation: $($script:OriginalSourcePath))..."
    Write-Log "Deployment Type wrappers LOCKED: Install='$($script:InstallInfo.Comando)' | Uninstall='$($script:UninstallInfo.Comando)'"
    Write-Log "PowerShell Detection Method prepared: $($script:DetectionText.Length) character(s)."
    $result = New-SCCMScriptApplication `
        -AppName $txtAppName.Text `
        -Publisher $txtPublisher.Text `
        -Version $txtVersion.Text `
        -SourceFolder $script:OriginalSourcePath `
        -InstallCommand $script:InstallInfo.Comando `
        -UninstallCommand $script:UninstallInfo.Comando `
        -DetectionScript $script:DetectionText

    if ($result.Success) {
        Write-Log $result.Mensagem
        [System.Windows.Forms.MessageBox]::Show($result.Mensagem, "Success") | Out-Null
    } else {
        Write-Log "ERROR: $($result.Mensagem)"
        [System.Windows.Forms.MessageBox]::Show($result.Mensagem, "Error", 'OK', 'Error') | Out-Null
    }
})

$form.Add_FormClosing({
    if (Get-PSDrive -Name 'SCCMSRC' -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name 'SCCMSRC' -Force -ErrorAction SilentlyContinue
    }
})

Write-Log "Tool started. Connect to SCCM and enter the application details."
# --- Aplica o estilo visual Windows 11 (aditivo, nao interfere na logica) ---
Enable-Windows11Style -FormObject $form

[void]$form.ShowDialog()
