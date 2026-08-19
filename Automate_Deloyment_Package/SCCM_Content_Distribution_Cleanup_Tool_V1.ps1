<#
.SYNOPSIS
    SCCM Content Distribution Cleanup Tool - V1

.DESCRIPTION
    Interface grafica PowerShell para remover conteudo de:
      - Applications
      - Packages (legacy)
      - Software Update Deployment Packages

    de um ou mais Distribution Points, sem excluir o objeto do Configuration Manager.

    A ferramenta NAO contem informacoes de ambiente.
    O usuario informa Site Server e Site Code na interface ou por parametros opcionais.

.REQUIREMENTS
    - Windows PowerShell 5.1
    - Console do Microsoft Configuration Manager instalado
    - Permissoes RBAC adequadas no Configuration Manager
    - Acesso ao SMS Provider / Site Server

.NOTES
    V1 - foco em seguranca:
      - Nao exclui Application, Package ou Update Deployment Package do site.
      - Usa Remove-CMContentDistribution.
      - Preview usa -WhatIf.
      - Para Applications, preserva por padrao o conteudo de dependencias
        usando -DisableContentDependencyDetection.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SiteServer = '',

    [Parameter(Mandatory = $false)]
    [string]$SiteCode = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# Estado global da aplicacao
# ============================================================
$script:Connected = $false
$script:CurrentObject = $null
$script:CurrentObjectType = $null
$script:CurrentObjectName = $null
$script:CurrentPackageId = $null
$script:OriginalLocation = Get-Location

# ============================================================
# Helpers
# ============================================================
function Write-UiLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','OK','WARN','ERROR','PREVIEW')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        $script:txtLog.SelectionStart = $script:txtLog.TextLength
        $script:txtLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-StatusText {
    param(
        [string]$Text,
        [System.Drawing.Color]$Color = [System.Drawing.Color]::DimGray
    )
    $script:lblStatus.Text = $Text
    $script:lblStatus.ForeColor = $Color
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-ConfigurationManagerModulePath {
    $loaded = Get-Module -Name ConfigurationManager -ErrorAction SilentlyContinue
    if ($loaded) {
        return $loaded.Path
    }

    $available = Get-Module -ListAvailable -Name ConfigurationManager -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($available) {
        return $available.Path
    }

    if ($env:SMS_ADMIN_UI_PATH) {
        $consoleBin = Split-Path -Path $env:SMS_ADMIN_UI_PATH -Parent
        $candidate = Join-Path $consoleBin 'ConfigurationManager.psd1'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $genericCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'),
        (Join-Path $env:ProgramFiles 'Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    return ($genericCandidates | Select-Object -First 1)
}

function Ensure-CmConnection {
    if (-not $script:Connected) {
        throw 'Conecte-se ao Configuration Manager antes de executar esta operacao.'
    }

    $driveName = $script:txtSiteCode.Text.Trim().ToUpperInvariant()
    if (-not (Get-PSDrive -Name $driveName -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        throw "O PSDrive '$driveName`:' nao esta disponivel. Reconecte-se ao site."
    }

    Set-Location "$driveName`:"
}

function Get-ObjectPackageId {
    param($Object)

    foreach ($property in @('PackageID','PackageId','PkgID')) {
        if ($Object.PSObject.Properties.Name -contains $property) {
            $value = $Object.$property
            if ($value) { return [string]$value }
        }
    }

    return ''
}

function Get-ObjectDisplayName {
    param($Object)

    foreach ($property in @('LocalizedDisplayName','Name','SoftwareName','PackageName')) {
        if ($Object.PSObject.Properties.Name -contains $property) {
            $value = $Object.$property
            if ($value) { return [string]$value }
        }
    }

    return '(sem nome)'
}

function Get-DpServerName {
    param($Object)

    foreach ($property in @(
        'SiteSystemServerName',
        'ServerName',
        'Name',
        'NetworkOSPath',
        'NALPath'
    )) {
        if ($Object.PSObject.Properties.Name -contains $property) {
            $value = [string]$Object.$property
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                # Remove prefixos UNC quando presentes.
                $value = $value.Trim()
                if ($value.StartsWith('\\')) {
                    $value = $value.TrimStart('\')
                    if ($value.Contains('\')) {
                        $value = $value.Split('\')[0]
                    }
                }
                return $value
            }
        }
    }

    return ''
}

function Clear-SelectedContent {
    $script:CurrentObject = $null
    $script:CurrentObjectType = $null
    $script:CurrentObjectName = $null
    $script:CurrentPackageId = $null

    $script:lblSelected.Text = 'Nenhum conteudo selecionado'
    $script:lblDistSummary.Text = 'Distribution Status: -'
    $script:dgvDPs.Rows.Clear()
}

function Show-RemoveConfirmation {
    param(
        [string]$ContentName,
        [string]$ContentType,
        [int]$DpCount
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Confirmacao de remocao de conteudo'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = New-Object System.Drawing.Size(600, 330)
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.FormBorderStyle = 'FixedDialog'

    $lblWarning = New-Object System.Windows.Forms.Label
    $lblWarning.Location = New-Object System.Drawing.Point(20, 20)
    $lblWarning.Size = New-Object System.Drawing.Size(545, 145)
    $lblWarning.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $lblWarning.Text = @"
Voce esta prestes a remover o CONTEUDO dos Distribution Points.

Tipo: $ContentType
Conteudo: $ContentName
Distribution Points selecionados: $DpCount

O objeto do Configuration Manager NAO sera excluido.
Digite REMOVER abaixo para confirmar.
"@
    $dialog.Controls.Add($lblWarning)

    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.Location = New-Object System.Drawing.Point(20, 180)
    $txtConfirm.Size = New-Object System.Drawing.Size(545, 28)
    $txtConfirm.Font = New-Object System.Drawing.Font('Consolas', 11)
    $dialog.Controls.Add($txtConfirm)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(350, 230)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 34)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel)

    $btnConfirm = New-Object System.Windows.Forms.Button
    $btnConfirm.Text = 'Remover'
    $btnConfirm.Location = New-Object System.Drawing.Point(465, 230)
    $btnConfirm.Size = New-Object System.Drawing.Size(100, 34)
    $btnConfirm.Enabled = $false
    $dialog.Controls.Add($btnConfirm)

    $txtConfirm.Add_TextChanged({
        $btnConfirm.Enabled = ($txtConfirm.Text.Trim().ToUpperInvariant() -eq 'REMOVER')
    })

    $btnConfirm.Add_Click({
        if ($txtConfirm.Text.Trim().ToUpperInvariant() -eq 'REMOVER') {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })

    $dialog.AcceptButton = $btnConfirm
    $dialog.CancelButton = $btnCancel

    $result = $dialog.ShowDialog($script:form)
    $dialog.Dispose()

    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Get-SelectedDpNames {
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($row in $script:dgvDPs.Rows) {
        if ($row.IsNewRow) { continue }

        $checked = $false
        if ($null -ne $row.Cells['Selected'].Value) {
            $checked = [bool]$row.Cells['Selected'].Value
        }

        if ($checked) {
            $name = [string]$row.Cells['DPName'].Value
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                $names.Add($name)
            }
        }
    }

    return $names.ToArray()
}

function Refresh-DpList {
    Ensure-CmConnection

    $script:dgvDPs.Rows.Clear()
    Set-StatusText 'Carregando Distribution Points...'

    $dps = @(Get-CMDistributionPointInfo -ErrorAction Stop)

    $unique = @{}
    foreach ($dp in $dps) {
        $name = Get-DpServerName -Object $dp
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $unique[$name.ToLowerInvariant()] = $name
        }
    }

    foreach ($name in ($unique.Values | Sort-Object)) {
        $idx = $script:dgvDPs.Rows.Add()
        $row = $script:dgvDPs.Rows[$idx]
        $row.Cells['Selected'].Value = $true
        $row.Cells['DPName'].Value = $name
        $row.Cells['Result'].Value = 'Pronto'
    }

    Write-UiLog "Distribution Points carregados: $($unique.Count)." 'OK'
    Set-StatusText "Conectado. DPs carregados: $($unique.Count)." ([System.Drawing.Color]::DarkGreen)
}

function Refresh-DistributionSummary {
    if (-not $script:CurrentObject) { return }

    try {
        Ensure-CmConnection
        $status = Get-CMDistributionStatus -InputObject $script:CurrentObject -ErrorAction Stop

        if ($status) {
            $targeted = if ($status.PSObject.Properties.Name -contains 'Targeted') { $status.Targeted } else { '?' }
            $success = if ($status.PSObject.Properties.Name -contains 'NumberSuccess') { $status.NumberSuccess } else { '?' }
            $progress = if ($status.PSObject.Properties.Name -contains 'NumberInProgress') { $status.NumberInProgress } else { '?' }
            $errors = if ($status.PSObject.Properties.Name -contains 'NumberErrors') { $status.NumberErrors } else { '?' }
            $unknown = if ($status.PSObject.Properties.Name -contains 'NumberUnknown') { $status.NumberUnknown } else { '?' }

            $script:lblDistSummary.Text =
                "Distribution Status | Targeted: $targeted | Success: $success | In Progress: $progress | Errors: $errors | Unknown: $unknown"
        }
        else {
            $script:lblDistSummary.Text = 'Distribution Status: nenhum status retornado.'
        }
    }
    catch {
        $script:lblDistSummary.Text = "Distribution Status: nao foi possivel consultar ($($_.Exception.Message))"
        Write-UiLog "Falha ao consultar Distribution Status: $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-ContentRemoval {
    param(
        [switch]$Preview
    )

    Ensure-CmConnection

    if (-not $script:CurrentObject) {
        [System.Windows.Forms.MessageBox]::Show(
            'Selecione um conteudo na lista de resultados.',
            'Conteudo nao selecionado',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $dpNames = @(Get-SelectedDpNames)
    if ($dpNames.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Selecione pelo menos um Distribution Point.',
            'Nenhum DP selecionado',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    if (-not $Preview) {
        $confirmed = Show-RemoveConfirmation `
            -ContentName $script:CurrentObjectName `
            -ContentType $script:CurrentObjectType `
            -DpCount $dpNames.Count

        if (-not $confirmed) {
            Write-UiLog 'Operacao cancelada pelo usuario.' 'WARN'
            return
        }
    }

    $script:btnPreview.Enabled = $false
    $script:btnRemove.Enabled = $false
    $script:btnSearch.Enabled = $false
    $script:btnConnect.Enabled = $false

    try {
        $modeLabel = if ($Preview) { 'PREVIEW / WHATIF' } else { 'REMOCAO' }
        Write-UiLog "$modeLabel iniciado para '$($script:CurrentObjectName)' em $($dpNames.Count) DP(s)." $(if ($Preview) {'PREVIEW'} else {'INFO'})

        $done = 0
        foreach ($dpName in $dpNames) {
            $done++
            Set-StatusText "$modeLabel - $done/$($dpNames.Count): $dpName"

            foreach ($row in $script:dgvDPs.Rows) {
                if (-not $row.IsNewRow -and [string]$row.Cells['DPName'].Value -eq $dpName) {
                    $row.Cells['Result'].Value = if ($Preview) { 'Preview...' } else { 'Removendo...' }
                    break
                }
            }

            [System.Windows.Forms.Application]::DoEvents()

            try {
                $params = @{
                    InputObject            = $script:CurrentObject
                    DistributionPointName = $dpName
                    ErrorAction            = 'Stop'
                }

                # Seguranca: por padrao, nao remover automaticamente o conteudo
                # das Applications dependentes.
                if ($script:CurrentObjectType -eq 'Application' -and $script:chkPreserveDependencies.Checked) {
                    $params['DisableContentDependencyDetection'] = $true
                }

                if ($Preview) {
                    $params['WhatIf'] = $true
                    Remove-CMContentDistribution @params
                    $resultText = 'WhatIf OK'
                    Write-UiLog "WHATIF: $($script:CurrentObjectName) -> $dpName" 'PREVIEW'
                }
                else {
                    $params['Force'] = $true
                    Remove-CMContentDistribution @params
                    $resultText = 'Solicitado'
                    Write-UiLog "Remocao solicitada: $($script:CurrentObjectName) -> $dpName" 'OK'
                }

                foreach ($row in $script:dgvDPs.Rows) {
                    if (-not $row.IsNewRow -and [string]$row.Cells['DPName'].Value -eq $dpName) {
                        $row.Cells['Result'].Value = $resultText
                        break
                    }
                }
            }
            catch {
                $message = $_.Exception.Message
                foreach ($row in $script:dgvDPs.Rows) {
                    if (-not $row.IsNewRow -and [string]$row.Cells['DPName'].Value -eq $dpName) {
                        $row.Cells['Result'].Value = 'ERRO'
                        break
                    }
                }
                Write-UiLog "Falha em $dpName: $message" 'ERROR'
            }
        }

        if ($Preview) {
            Set-StatusText 'Preview concluido. Nenhuma alteracao foi executada.' ([System.Drawing.Color]::DarkBlue)
        }
        else {
            Set-StatusText 'Solicitacoes de remocao concluidas. Atualize o status apos o processamento do site.' ([System.Drawing.Color]::DarkGreen)
            Refresh-DistributionSummary
        }
    }
    finally {
        $script:btnPreview.Enabled = $true
        $script:btnRemove.Enabled = $true
        $script:btnSearch.Enabled = $true
        $script:btnConnect.Enabled = $true
    }
}

# ============================================================
# Form principal
# ============================================================
$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = 'SCCM Content Distribution Cleanup Tool - V1'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 820)
$form.MinimumSize = New-Object System.Drawing.Size(1050, 720)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# ---------------- Connection ----------------
$grpConnection = New-Object System.Windows.Forms.GroupBox
$grpConnection.Text = 'Conexao com Configuration Manager'
$grpConnection.Location = New-Object System.Drawing.Point(12, 12)
$grpConnection.Size = New-Object System.Drawing.Size(1138, 100)
$grpConnection.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpConnection)

$lblServer = New-Object System.Windows.Forms.Label
$lblServer.Text = 'Site Server / SMS Provider:'
$lblServer.Location = New-Object System.Drawing.Point(18, 30)
$lblServer.Size = New-Object System.Drawing.Size(170, 22)
$grpConnection.Controls.Add($lblServer)

$txtSiteServer = New-Object System.Windows.Forms.TextBox
$txtSiteServer.Location = New-Object System.Drawing.Point(190, 27)
$txtSiteServer.Size = New-Object System.Drawing.Size(300, 25)
$txtSiteServer.Text = $SiteServer
$grpConnection.Controls.Add($txtSiteServer)
$script:txtSiteServer = $txtSiteServer

$lblCode = New-Object System.Windows.Forms.Label
$lblCode.Text = 'Site Code:'
$lblCode.Location = New-Object System.Drawing.Point(510, 30)
$lblCode.Size = New-Object System.Drawing.Size(70, 22)
$grpConnection.Controls.Add($lblCode)

$txtSiteCode = New-Object System.Windows.Forms.TextBox
$txtSiteCode.Location = New-Object System.Drawing.Point(585, 27)
$txtSiteCode.Size = New-Object System.Drawing.Size(85, 25)
$txtSiteCode.CharacterCasing = 'Upper'
$txtSiteCode.MaxLength = 3
$txtSiteCode.Text = $SiteCode
$grpConnection.Controls.Add($txtSiteCode)
$script:txtSiteCode = $txtSiteCode

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = 'Conectar'
$btnConnect.Location = New-Object System.Drawing.Point(690, 24)
$btnConnect.Size = New-Object System.Drawing.Size(110, 32)
$grpConnection.Controls.Add($btnConnect)
$script:btnConnect = $btnConnect

$lblConnection = New-Object System.Windows.Forms.Label
$lblConnection.Text = 'Nao conectado'
$lblConnection.ForeColor = [System.Drawing.Color]::Firebrick
$lblConnection.Location = New-Object System.Drawing.Point(820, 30)
$lblConnection.Size = New-Object System.Drawing.Size(285, 22)
$grpConnection.Controls.Add($lblConnection)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = 'Requer o console do Configuration Manager instalado e permissoes RBAC adequadas.'
$lblHint.ForeColor = [System.Drawing.Color]::DimGray
$lblHint.Location = New-Object System.Drawing.Point(18, 66)
$lblHint.Size = New-Object System.Drawing.Size(800, 20)
$grpConnection.Controls.Add($lblHint)

# ---------------- Search ----------------
$grpSearch = New-Object System.Windows.Forms.GroupBox
$grpSearch.Text = 'Pesquisar conteudo'
$grpSearch.Location = New-Object System.Drawing.Point(12, 120)
$grpSearch.Size = New-Object System.Drawing.Size(1138, 205)
$grpSearch.Anchor = 'Top,Left,Right'
$form.Controls.Add($grpSearch)

$lblType = New-Object System.Windows.Forms.Label
$lblType.Text = 'Tipo:'
$lblType.Location = New-Object System.Drawing.Point(18, 30)
$lblType.Size = New-Object System.Drawing.Size(40, 22)
$grpSearch.Controls.Add($lblType)

$cmbType = New-Object System.Windows.Forms.ComboBox
$cmbType.Location = New-Object System.Drawing.Point(62, 27)
$cmbType.Size = New-Object System.Drawing.Size(245, 25)
$cmbType.DropDownStyle = 'DropDownList'
[void]$cmbType.Items.Add('Todos')
[void]$cmbType.Items.Add('Application')
[void]$cmbType.Items.Add('Package')
[void]$cmbType.Items.Add('Software Update Deployment Package')
$cmbType.SelectedIndex = 0
$grpSearch.Controls.Add($cmbType)

$lblSearch = New-Object System.Windows.Forms.Label
$lblSearch.Text = 'Nome contem:'
$lblSearch.Location = New-Object System.Drawing.Point(330, 30)
$lblSearch.Size = New-Object System.Drawing.Size(90, 22)
$grpSearch.Controls.Add($lblSearch)

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Location = New-Object System.Drawing.Point(420, 27)
$txtSearch.Size = New-Object System.Drawing.Size(430, 25)
$grpSearch.Controls.Add($txtSearch)

$btnSearch = New-Object System.Windows.Forms.Button
$btnSearch.Text = 'Pesquisar'
$btnSearch.Location = New-Object System.Drawing.Point(870, 24)
$btnSearch.Size = New-Object System.Drawing.Size(105, 32)
$grpSearch.Controls.Add($btnSearch)
$script:btnSearch = $btnSearch

$dgvResults = New-Object System.Windows.Forms.DataGridView
$dgvResults.Location = New-Object System.Drawing.Point(18, 66)
$dgvResults.Size = New-Object System.Drawing.Size(1095, 120)
$dgvResults.Anchor = 'Top,Left,Right'
$dgvResults.AllowUserToAddRows = $false
$dgvResults.AllowUserToDeleteRows = $false
$dgvResults.ReadOnly = $true
$dgvResults.MultiSelect = $false
$dgvResults.SelectionMode = 'FullRowSelect'
$dgvResults.AutoSizeColumnsMode = 'Fill'
$dgvResults.RowHeadersVisible = $false

[void]$dgvResults.Columns.Add('Type','Tipo')
[void]$dgvResults.Columns.Add('Name','Nome')
[void]$dgvResults.Columns.Add('PackageId','Package ID')
[void]$dgvResults.Columns.Add('Version','Versao')

$dgvResults.Columns['Type'].FillWeight = 24
$dgvResults.Columns['Name'].FillWeight = 52
$dgvResults.Columns['PackageId'].FillWeight = 20
$dgvResults.Columns['Version'].FillWeight = 14

$grpSearch.Controls.Add($dgvResults)
$script:dgvResults = $dgvResults

# ---------------- DP Section ----------------
$grpDP = New-Object System.Windows.Forms.GroupBox
$grpDP.Text = 'Distribution Points'
$grpDP.Location = New-Object System.Drawing.Point(12, 333)
$grpDP.Size = New-Object System.Drawing.Size(1138, 270)
$grpDP.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($grpDP)

$lblSelected = New-Object System.Windows.Forms.Label
$lblSelected.Text = 'Nenhum conteudo selecionado'
$lblSelected.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$lblSelected.Location = New-Object System.Drawing.Point(18, 26)
$lblSelected.Size = New-Object System.Drawing.Size(650, 22)
$grpDP.Controls.Add($lblSelected)
$script:lblSelected = $lblSelected

$lblDistSummary = New-Object System.Windows.Forms.Label
$lblDistSummary.Text = 'Distribution Status: -'
$lblDistSummary.ForeColor = [System.Drawing.Color]::DimGray
$lblDistSummary.Location = New-Object System.Drawing.Point(18, 50)
$lblDistSummary.Size = New-Object System.Drawing.Size(900, 20)
$grpDP.Controls.Add($lblDistSummary)
$script:lblDistSummary = $lblDistSummary

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = 'Marcar todos'
$btnSelectAll.Location = New-Object System.Drawing.Point(918, 24)
$btnSelectAll.Size = New-Object System.Drawing.Size(95, 30)
$grpDP.Controls.Add($btnSelectAll)

$btnSelectNone = New-Object System.Windows.Forms.Button
$btnSelectNone.Text = 'Desmarcar'
$btnSelectNone.Location = New-Object System.Drawing.Point(1018, 24)
$btnSelectNone.Size = New-Object System.Drawing.Size(95, 30)
$grpDP.Controls.Add($btnSelectNone)

$dgvDPs = New-Object System.Windows.Forms.DataGridView
$dgvDPs.Location = New-Object System.Drawing.Point(18, 78)
$dgvDPs.Size = New-Object System.Drawing.Size(1095, 145)
$dgvDPs.Anchor = 'Top,Bottom,Left,Right'
$dgvDPs.AllowUserToAddRows = $false
$dgvDPs.AllowUserToDeleteRows = $false
$dgvDPs.RowHeadersVisible = $false
$dgvDPs.SelectionMode = 'FullRowSelect'
$dgvDPs.AutoSizeColumnsMode = 'Fill'

$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.Name = 'Selected'
$colCheck.HeaderText = 'Selecionar'
$colCheck.FillWeight = 12
[void]$dgvDPs.Columns.Add($colCheck)

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name = 'DPName'
$colName.HeaderText = 'Distribution Point'
$colName.ReadOnly = $true
$colName.FillWeight = 68
[void]$dgvDPs.Columns.Add($colName)

$colResult = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colResult.Name = 'Result'
$colResult.HeaderText = 'Resultado'
$colResult.ReadOnly = $true
$colResult.FillWeight = 20
[void]$dgvDPs.Columns.Add($colResult)

$grpDP.Controls.Add($dgvDPs)
$script:dgvDPs = $dgvDPs

$chkPreserveDependencies = New-Object System.Windows.Forms.CheckBox
$chkPreserveDependencies.Text = 'Application: preservar conteudo de dependencias'
$chkPreserveDependencies.Checked = $true
$chkPreserveDependencies.Location = New-Object System.Drawing.Point(18, 232)
$chkPreserveDependencies.Size = New-Object System.Drawing.Size(350, 24)
$grpDP.Controls.Add($chkPreserveDependencies)
$script:chkPreserveDependencies = $chkPreserveDependencies

$btnRefreshDP = New-Object System.Windows.Forms.Button
$btnRefreshDP.Text = 'Atualizar DPs'
$btnRefreshDP.Location = New-Object System.Drawing.Point(875, 229)
$btnRefreshDP.Size = New-Object System.Drawing.Size(110, 30)
$grpDP.Controls.Add($btnRefreshDP)

$btnRefreshStatus = New-Object System.Windows.Forms.Button
$btnRefreshStatus.Text = 'Atualizar Status'
$btnRefreshStatus.Location = New-Object System.Drawing.Point(995, 229)
$btnRefreshStatus.Size = New-Object System.Drawing.Size(118, 30)
$grpDP.Controls.Add($btnRefreshStatus)

# ---------------- Actions ----------------
$grpActions = New-Object System.Windows.Forms.GroupBox
$grpActions.Text = 'Acoes seguras'
$grpActions.Location = New-Object System.Drawing.Point(12, 611)
$grpActions.Size = New-Object System.Drawing.Size(1138, 70)
$grpActions.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($grpActions)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = 'PREVIEW / WhatIf'
$btnPreview.Location = New-Object System.Drawing.Point(18, 26)
$btnPreview.Size = New-Object System.Drawing.Size(155, 32)
$grpActions.Controls.Add($btnPreview)
$script:btnPreview = $btnPreview

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = 'REMOVER DOS DPs'
$btnRemove.Location = New-Object System.Drawing.Point(185, 26)
$btnRemove.Size = New-Object System.Drawing.Size(170, 32)
$btnRemove.BackColor = [System.Drawing.Color]::MistyRose
$grpActions.Controls.Add($btnRemove)
$script:btnRemove = $btnRemove

$lblSafety = New-Object System.Windows.Forms.Label
$lblSafety.Text = 'Esta ferramenta remove somente o conteudo dos DPs. Ela nao exclui o objeto do Configuration Manager.'
$lblSafety.ForeColor = [System.Drawing.Color]::DarkRed
$lblSafety.Location = New-Object System.Drawing.Point(380, 32)
$lblSafety.Size = New-Object System.Drawing.Size(720, 22)
$grpActions.Controls.Add($lblSafety)

# ---------------- Log ----------------
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = 'Log'
$grpLog.Location = New-Object System.Drawing.Point(12, 689)
$grpLog.Size = New-Object System.Drawing.Size(1138, 82)
$grpLog.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($grpLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 22)
$txtLog.Size = New-Object System.Drawing.Size(955, 45)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$grpLog.Controls.Add($txtLog)
$script:txtLog = $txtLog

$btnSaveLog = New-Object System.Windows.Forms.Button
$btnSaveLog.Text = 'Salvar Log'
$btnSaveLog.Location = New-Object System.Drawing.Point(990, 25)
$btnSaveLog.Size = New-Object System.Drawing.Size(120, 32)
$btnSaveLog.Anchor = 'Top,Right'
$grpLog.Controls.Add($btnSaveLog)

# ---------------- Status bar ----------------
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Informe Site Server e Site Code e clique em Conectar.'
$lblStatus.Location = New-Object System.Drawing.Point(15, 775)
$lblStatus.Size = New-Object System.Drawing.Size(1120, 20)
$lblStatus.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($lblStatus)
$script:lblStatus = $lblStatus

# ============================================================
# Eventos
# ============================================================
$btnConnect.Add_Click({
    try {
        $server = $txtSiteServer.Text.Trim()
        $code = $txtSiteCode.Text.Trim().ToUpperInvariant()

        if ([string]::IsNullOrWhiteSpace($server)) {
            throw 'Informe o Site Server / SMS Provider.'
        }

        if ($code -notmatch '^[A-Za-z0-9]{3}$') {
            throw 'Informe um Site Code valido com 3 caracteres.'
        }

        Set-StatusText 'Localizando modulo ConfigurationManager...'
        Write-UiLog "Tentando conectar ao site '$code' usando o servidor informado." 'INFO'

        $modulePath = Get-ConfigurationManagerModulePath
        if (-not $modulePath) {
            throw 'Modulo ConfigurationManager nao encontrado. Instale o console do Microsoft Configuration Manager nesta maquina.'
        }

        Import-Module $modulePath -Force -ErrorAction Stop

        $existing = Get-PSDrive -Name $code -PSProvider CMSite -ErrorAction SilentlyContinue
        if ($existing) {
            # Se o drive existe, reutiliza. Nao removemos um drive que possa
            # ter sido criado por outra sessao/logica do administrador.
            Write-UiLog "PSDrive '$code`:' ja existe e sera reutilizado." 'INFO'
        }
        else {
            New-PSDrive -Name $code -PSProvider CMSite -Root $server -Description "SCCM Site $code" -ErrorAction Stop | Out-Null
            Write-UiLog "PSDrive '$code`:' criado com sucesso." 'OK'
        }

        Set-Location "$code`:"
        $script:Connected = $true

        $lblConnection.Text = "Conectado: $code"
        $lblConnection.ForeColor = [System.Drawing.Color]::DarkGreen

        Clear-SelectedContent
        Refresh-DpList

        Write-UiLog 'Conexao com o Configuration Manager concluida.' 'OK'
    }
    catch {
        $script:Connected = $false
        $lblConnection.Text = 'Falha na conexao'
        $lblConnection.ForeColor = [System.Drawing.Color]::Firebrick
        Set-StatusText $_.Exception.Message ([System.Drawing.Color]::Firebrick)
        Write-UiLog $_.Exception.Message 'ERROR'

        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            'Erro de conexao',
            'OK',
            'Error'
        ) | Out-Null
    }
})

$btnSearch.Add_Click({
    try {
        Ensure-CmConnection

        $term = $txtSearch.Text.Trim()
        if ($term.Length -lt 2) {
            throw 'Digite pelo menos 2 caracteres para pesquisar.'
        }

        $dgvResults.Rows.Clear()
        Clear-SelectedContent

        $filterType = [string]$cmbType.SelectedItem
        $pattern = "*$term*"
        $count = 0

        Set-StatusText "Pesquisando '$term'..."
        Write-UiLog "Pesquisa iniciada: '$term' | Tipo: $filterType" 'INFO'

        if ($filterType -in @('Todos','Application')) {
            $apps = @(Get-CMApplication -Name $pattern -ErrorAction SilentlyContinue)
            foreach ($obj in $apps) {
                $name = Get-ObjectDisplayName $obj
                $pkgId = Get-ObjectPackageId $obj
                $version = if ($obj.PSObject.Properties.Name -contains 'SoftwareVersion') { [string]$obj.SoftwareVersion } else { '' }

                $idx = $dgvResults.Rows.Add('Application',$name,$pkgId,$version)
                $dgvResults.Rows[$idx].Tag = $obj
                $count++
            }
        }

        if ($filterType -in @('Todos','Package')) {
            $packages = @(Get-CMPackage -Name $pattern -ErrorAction SilentlyContinue)
            foreach ($obj in $packages) {
                $name = Get-ObjectDisplayName $obj
                $pkgId = Get-ObjectPackageId $obj
                $version = if ($obj.PSObject.Properties.Name -contains 'Version') { [string]$obj.Version } else { '' }

                $idx = $dgvResults.Rows.Add('Package',$name,$pkgId,$version)
                $dgvResults.Rows[$idx].Tag = $obj
                $count++
            }
        }

        if ($filterType -in @('Todos','Software Update Deployment Package')) {
            $updates = @(Get-CMSoftwareUpdateDeploymentPackage -Name $pattern -ErrorAction SilentlyContinue)
            foreach ($obj in $updates) {
                $name = Get-ObjectDisplayName $obj
                $pkgId = Get-ObjectPackageId $obj

                $idx = $dgvResults.Rows.Add('Software Update Deployment Package',$name,$pkgId,'')
                $dgvResults.Rows[$idx].Tag = $obj
                $count++
            }
        }

        Set-StatusText "Pesquisa concluida. Resultados: $count." ([System.Drawing.Color]::DarkGreen)
        Write-UiLog "Pesquisa concluida. Resultados: $count." 'OK'
    }
    catch {
        Set-StatusText $_.Exception.Message ([System.Drawing.Color]::Firebrick)
        Write-UiLog $_.Exception.Message 'ERROR'
    }
})

$txtSearch.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        $btnSearch.PerformClick()
    }
})

$dgvResults.Add_SelectionChanged({
    try {
        if ($dgvResults.SelectedRows.Count -eq 0) { return }

        $row = $dgvResults.SelectedRows[0]
        if (-not $row.Tag) { return }

        $script:CurrentObject = $row.Tag
        $script:CurrentObjectType = [string]$row.Cells['Type'].Value
        $script:CurrentObjectName = [string]$row.Cells['Name'].Value
        $script:CurrentPackageId = [string]$row.Cells['PackageId'].Value

        $script:lblSelected.Text =
            "Selecionado: $($script:CurrentObjectType) | $($script:CurrentObjectName) | ID: $($script:CurrentPackageId)"

        $chkPreserveDependencies.Enabled = ($script:CurrentObjectType -eq 'Application')

        Write-UiLog "Conteudo selecionado: $($script:CurrentObjectType) | $($script:CurrentObjectName) | $($script:CurrentPackageId)" 'INFO'
        Refresh-DistributionSummary
    }
    catch {
        Write-UiLog "Erro ao selecionar conteudo: $($_.Exception.Message)" 'ERROR'
    }
})

$btnSelectAll.Add_Click({
    foreach ($row in $dgvDPs.Rows) {
        if (-not $row.IsNewRow) {
            $row.Cells['Selected'].Value = $true
        }
    }
})

$btnSelectNone.Add_Click({
    foreach ($row in $dgvDPs.Rows) {
        if (-not $row.IsNewRow) {
            $row.Cells['Selected'].Value = $false
        }
    }
})

$btnRefreshDP.Add_Click({
    try {
        Refresh-DpList
    }
    catch {
        Write-UiLog $_.Exception.Message 'ERROR'
        Set-StatusText $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
})

$btnRefreshStatus.Add_Click({
    if ($script:CurrentObject) {
        Refresh-DistributionSummary
    }
    else {
        Write-UiLog 'Selecione um conteudo antes de atualizar o status.' 'WARN'
    }
})

$btnPreview.Add_Click({
    try {
        Invoke-ContentRemoval -Preview
    }
    catch {
        Write-UiLog $_.Exception.Message 'ERROR'
        Set-StatusText $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
})

$btnRemove.Add_Click({
    try {
        Invoke-ContentRemoval
    }
    catch {
        Write-UiLog $_.Exception.Message 'ERROR'
        Set-StatusText $_.Exception.Message ([System.Drawing.Color]::Firebrick)
    }
})

$btnSaveLog.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Log files (*.log)|*.log|Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = "SCCM-Content-Cleanup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            [System.IO.File]::WriteAllText($dialog.FileName, $txtLog.Text, [System.Text.Encoding]::UTF8)
            Write-UiLog "Log salvo em: $($dialog.FileName)" 'OK'
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                'Erro ao salvar log',
                'OK',
                'Error'
            ) | Out-Null
        }
    }

    $dialog.Dispose()
})

$form.Add_FormClosing({
    try {
        Set-Location $script:OriginalLocation -ErrorAction SilentlyContinue
    }
    catch {}
})

# ============================================================
# Inicializacao
# ============================================================
Write-UiLog 'SCCM Content Distribution Cleanup Tool V1 iniciado.' 'INFO'
Write-UiLog 'A ferramenta nao exclui objetos do Configuration Manager; remove somente conteudo dos DPs.' 'INFO'

if (-not [string]::IsNullOrWhiteSpace($SiteServer) -and -not [string]::IsNullOrWhiteSpace($SiteCode)) {
    Write-UiLog 'Parametros de conexao recebidos. Clique em Conectar para iniciar.' 'INFO'
}

[void]$form.ShowDialog()
