#Requires -Version 5.0
<#
    Uninstall String Tool
    ----------------------
    Busca no Registro do Windows (e, se necessário, na pasta de instalação)
    a Uninstall String de um programa, e sugere a versão "silenciosa" dela
    (com base em padrões comuns: MSI /qn, InnoSetup /VERYSILENT, NSIS /S, etc).

    Uso: clique com o botão direito -> "Executar com PowerShell"
    (pode ser necessário rodar como Administrador para ver todos os programas)
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ----------------------------------------------------------------------
# Funções auxiliares
# ----------------------------------------------------------------------

function Get-InstalledPrograms {
    param([string]$Filter)

    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $results = foreach ($p in $paths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -match [regex]::Escape($Filter) }
    }

    $results | Sort-Object DisplayName -Unique
}

function Get-SilentSuggestion {
    param([string]$UninstallString)

    if (-not $UninstallString) { return $null }

    $us = $UninstallString.Trim()

    # MSI -> msiexec /X{GUID} /qn /norestart
    if ($us -match 'msiexec' -and $us -match '(\{[0-9A-Fa-f-]{36}\})') {
        $guid = $Matches[1]
        return "msiexec.exe /x $guid /qn /norestart"
    }

    # Já contém switches conhecidos de silencioso
    $knownSilent = @('/S', '/silent', '/verysilent', '/qn', '/quiet', '-silent', '--silent')
    foreach ($sw in $knownSilent) {
        if ($us -match [regex]::Escape($sw)) {
            return $us
        }
    }

    # Extrai o executável entre aspas ou até o primeiro espaço
    $exePath = $null
    if ($us -match '^\s*"([^"]+)"') {
        $exePath = $Matches[1]
    } elseif ($us -match '^\s*(\S+\.exe)') {
        $exePath = $Matches[1]
    }

    if (-not $exePath) { return "$us  (não foi possível identificar padrão silencioso)" }

    $exeName = [IO.Path]::GetFileName($exePath).ToLower()

    # Heurísticas por instalador comum
    switch -Regex ($exeName) {
        'unins\d*\.exe'      { return "`"$exePath`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" } # Inno Setup
        'uninstall\.exe'     { return "`"$exePath`" /S" }                                        # NSIS (comum)
        'setup\.exe'         { return "`"$exePath`" /S" }
        default               { return "`"$exePath`" /S   (heurística genérica — confira com /? ou /help)" }
    }
}

function Search-InstallFolder {
    param([string]$FolderPath)

    if (-not $FolderPath -or -not (Test-Path $FolderPath)) { return @() }

    Get-ChildItem -Path $FolderPath -Recurse -Include 'unins*.exe','uninstall*.exe','setup.exe' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
}

# ----------------------------------------------------------------------
# Interface Gráfica
# ----------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Uninstall String Tool"
$form.Size = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(650, 450)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = "Nome do software (ou parte do nome):"
$lblSearch.Location = New-Object System.Drawing.Point(12, 15)
$lblSearch.AutoSize = $true
$form.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(15, 38)
$txtSearch.Size = New-Object System.Drawing.Size(500, 24)
$txtSearch.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtSearch)

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = "Buscar"
$btnSearch.Location = New-Object System.Drawing.Point(525, 37)
$btnSearch.Size = New-Object System.Drawing.Size(100, 26)
$btnSearch.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnSearch)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = "Buscar em pasta..."
$btnFolder.Location = New-Object System.Drawing.Point(635, 37)
$btnFolder.Size = New-Object System.Drawing.Size(105, 26)
$btnFolder.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnFolder)

$lstResults = New-Object System.Windows.Forms.ListBox
$lstResults.Location = New-Object System.Drawing.Point(15, 75)
$lstResults.Size = New-Object System.Drawing.Size(725, 120)
$lstResults.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($lstResults)

$lblDetails = New-Object System.Windows.Forms.Label
$lblDetails.Text = "Detalhes:"
$lblDetails.Location = New-Object System.Drawing.Point(15, 205)
$lblDetails.AutoSize = $true
$lblDetails.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($lblDetails)

$txtDetails = New-Object System.Windows.Forms.TextBox
$txtDetails.Location = New-Object System.Drawing.Point(15, 228)
$txtDetails.Size = New-Object System.Drawing.Size(725, 130)
$txtDetails.Multiline = $true
$txtDetails.ScrollBars = "Vertical"
$txtDetails.ReadOnly = $true
$txtDetails.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtDetails)

$lblSilent = New-Object System.Windows.Forms.Label
$lblSilent.Text = "Sugestão de comando silencioso:"
$lblSilent.Location = New-Object System.Drawing.Point(15, 368)
$lblSilent.AutoSize = $true
$form.Controls.Add($lblSilent)

$txtSilent = New-Object System.Windows.Forms.TextBox
$txtSilent.Location = New-Object System.Drawing.Point(15, 391)
$txtSilent.Size = New-Object System.Drawing.Size(600, 24)
$txtSilent.ReadOnly = $true
$txtSilent.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtSilent)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Copiar"
$btnCopy.Location = New-Object System.Drawing.Point(625, 390)
$btnCopy.Size = New-Object System.Drawing.Size(115, 26)
$btnCopy.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnCopy)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Pronto."
$statusStrip.Items.Add($statusLabel) | Out-Null
$form.Controls.Add($statusStrip)

$note = New-Object System.Windows.Forms.Label
$note.Text = "Dica: rode como Administrador para enxergar todos os programas instalados (inclusive de outros usuários)."
$note.Location = New-Object System.Drawing.Point(15, 425)
$note.Size = New-Object System.Drawing.Size(725, 40)
$note.ForeColor = [System.Drawing.Color]::DimGray
$note.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($note)

# guarda os objetos completos encontrados (DisplayName -> objeto do registro)
$script:currentResults = @{}

# ----------------------------------------------------------------------
# Eventos
# ----------------------------------------------------------------------

$btnSearch.Add_Click({
    $term = $txtSearch.Text.Trim()
    $lstResults.Items.Clear()
    $txtDetails.Clear()
    $txtSilent.Clear()
    $script:currentResults.Clear()

    if (-not $term) {
        $statusLabel.Text = "Digite o nome de um software para buscar."
        return
    }

    $statusLabel.Text = "Buscando no registro..."
    $form.Refresh()

    $programs = Get-InstalledPrograms -Filter $term

    if (-not $programs) {
        $statusLabel.Text = "Nenhum programa encontrado no registro para '$term'."
        [System.Windows.Forms.MessageBox]::Show(
            "Nenhum programa encontrado no registro com esse nome.`nTente usar o botão 'Buscar em pasta...' para procurar um executável de desinstalação manualmente.",
            "Uninstall String Tool", "OK", "Information") | Out-Null
        return
    }

    foreach ($p in $programs) {
        $label = $p.DisplayName
        if ($p.DisplayVersion) { $label += "  (v$($p.DisplayVersion))" }
        $lstResults.Items.Add($label) | Out-Null
        $script:currentResults[$label] = $p
    }

    $statusLabel.Text = "$($programs.Count) programa(s) encontrado(s)."
})

$lstResults.Add_SelectedIndexChanged({
    if ($lstResults.SelectedItem -eq $null) { return }

    $p = $script:currentResults[$lstResults.SelectedItem]
    if (-not $p) { return }

    $uninstallStr = $p.UninstallString
    $quietStr     = $p.QuietUninstallString
    $installLoc   = $p.InstallLocation

    $details = @()
    $details += "Nome:              $($p.DisplayName)"
    if ($p.DisplayVersion) { $details += "Versão:            $($p.DisplayVersion)" }
    if ($p.Publisher)      { $details += "Fabricante:        $($p.Publisher)" }
    if ($installLoc)       { $details += "Pasta instalação:  $installLoc" }
    $details += ""
    $details += "UninstallString:       $uninstallStr"
    if ($quietStr) { $details += "QuietUninstallString: $quietStr" }

    $txtDetails.Text = $details -join "`r`n"

    if ($quietStr) {
        # o próprio fabricante já forneceu a versão silenciosa
        $txtSilent.Text = $quietStr
    } else {
        $txtSilent.Text = Get-SilentSuggestion -UninstallString $uninstallStr
    }
})

$btnFolder.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Selecione a pasta onde o programa está instalado"
    if ($dlg.ShowDialog() -ne "OK") { return }

    $statusLabel.Text = "Buscando executáveis de desinstalação na pasta..."
    $form.Refresh()

    $found = Search-InstallFolder -FolderPath $dlg.SelectedPath

    if (-not $found) {
        $statusLabel.Text = "Nenhum executável de desinstalação encontrado nessa pasta."
        [System.Windows.Forms.MessageBox]::Show(
            "Não foi encontrado nenhum unins*.exe, uninstall*.exe ou setup.exe nessa pasta.",
            "Uninstall String Tool", "OK", "Warning") | Out-Null
        return
    }

    $lstResults.Items.Clear()
    $script:currentResults.Clear()

    foreach ($exe in $found) {
        $label = $exe
        $lstResults.Items.Add($label) | Out-Null
        # cria um "objeto fake" só com UninstallString para reaproveitar a lógica de sugestão
        $script:currentResults[$label] = [PSCustomObject]@{
            DisplayName          = [IO.Path]::GetFileName($exe)
            DisplayVersion       = $null
            Publisher            = $null
            InstallLocation      = $dlg.SelectedPath
            UninstallString      = "`"$exe`""
            QuietUninstallString = $null
        }
    }

    $statusLabel.Text = "$($found.Count) executável(is) encontrado(s) na pasta."
})

$btnCopy.Add_Click({
    if ($txtSilent.Text) {
        [System.Windows.Forms.Clipboard]::SetText($txtSilent.Text)
        $statusLabel.Text = "Comando copiado para a área de transferência."
    }
})

$txtSearch.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq "Enter") {
        $btnSearch.PerformClick()
        $e.SuppressKeyPress = $true
    }
})

# ----------------------------------------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
