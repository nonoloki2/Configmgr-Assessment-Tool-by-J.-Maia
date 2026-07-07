# ConfigMgr Assessment Tool by J. Maia
# Version: 1.0.4-alpha - Phase 1 Fixed MVP

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:ModulesPath = Join-Path $Script:ToolRoot 'Modules'
$Script:OutputPath = Join-Path $Script:ToolRoot 'Output'
$Script:CsvPath = Join-Path $Script:OutputPath 'CSV'
$Script:LogPath = Join-Path $Script:OutputPath 'Logs'


function Ensure-OutputFolders {
    $folders = @(
        $Script:OutputPath,
        $Script:CsvPath,
        $Script:LogPath,
        (Join-Path $Script:OutputPath 'Reports')
    )

    foreach ($folder in $folders) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        try {
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
            }
            $gitkeep = Join-Path $folder '.gitkeep'
            if (-not (Test-Path -LiteralPath $gitkeep)) {
                New-Item -ItemType File -Path $gitkeep -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }
        catch {
            throw "Failed to create required folder '$folder'. Error: $($_.Exception.Message)"
        }
    }
}

function Initialize-LogFile {
    param([string]$RequestedLogFile)

    try {
        $parent = Split-Path -Parent $RequestedLogFile
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        New-Item -ItemType File -Path $RequestedLogFile -Force -ErrorAction Stop | Out-Null
        return $RequestedLogFile
    }
    catch {
        $fallbackRoot = Join-Path $env:TEMP 'ConfigMgrAssessmentTool_by_J_Maia'
        $fallbackLog = Join-Path $fallbackRoot (Split-Path -Leaf $RequestedLogFile)
        if (-not (Test-Path -LiteralPath $fallbackRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $fallbackRoot -Force -ErrorAction Stop | Out-Null
        }
        New-Item -ItemType File -Path $fallbackLog -Force -ErrorAction Stop | Out-Null
        Write-Warning "Could not create log under project Output folder. Using fallback log: $fallbackLog"
        return $fallbackLog
    }
}

Ensure-OutputFolders

Import-Module (Join-Path $Script:ModulesPath 'Common.psm1') -Force
Import-Module (Join-Path $Script:ModulesPath 'Export.psm1') -Force
Import-Module (Join-Path $Script:ModulesPath 'Discovery.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Script:AssessmentId = ([guid]::NewGuid()).Guid.ToUpper()
$Script:Results = New-Object System.Collections.Generic.List[object]
$Script:CurrentLogFile = Join-Path $Script:LogPath "ConfigMgr_Assessment_$((Get-Date).ToString('yyyyMMdd_HHmmss'))_$($Script:AssessmentId).log"
$Script:CurrentLogFile = Initialize-LogFile -RequestedLogFile $Script:CurrentLogFile
Write-Host "ConfigMgr Assessment Tool startup log: $Script:CurrentLogFile"
if ($Script:ToolRoot.Length -gt 140) { Write-Warning "Project path is long ($($Script:ToolRoot.Length) chars). CSV/log export may use TEMP fallback if Windows path length limit is hit." }
$Script:LastCsvFile = $null

function Write-UiLog {
    param([string]$Message)
    Ensure-OutputFolders
    $timestamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[$timestamp] $Message"
    try {
        $parent = Split-Path -Parent $Script:CurrentLogFile
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -LiteralPath $Script:CurrentLogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        $fallbackRoot = Join-Path $env:TEMP 'ConfigMgrAssessmentTool_by_J_Maia'
        if (-not (Test-Path -LiteralPath $fallbackRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $fallbackRoot -Force | Out-Null
        }
        $Script:CurrentLogFile = Join-Path $fallbackRoot ("ConfigMgr_Assessment_FALLBACK_$((Get-Date).ToString('yyyyMMdd_HHmmss'))_$($Script:AssessmentId).log")
        Add-Content -LiteralPath $Script:CurrentLogFile -Value $line -Encoding UTF8
    }
    $txtLog.AppendText($line + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-UiProgress {
    param([int]$Percent, [string]$Activity)
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $progress.Value = $Percent
    $lblCurrentTask.Text = "Current task: $Activity"
    [System.Windows.Forms.Application]::DoEvents()
}

function Refresh-ResultsGrid {
    $grid.Rows.Clear()
    foreach ($r in $Script:Results) {
        [void]$grid.Rows.Add($r.Status, $r.Category, $r.Check, $r.TargetServer, $r.Role, $r.Finding)
    }
}

function Refresh-TopologyTree {
    $tree.Nodes.Clear()
    $siteCode = $txtSiteCode.Text.Trim().ToUpper()
    $root = New-Object System.Windows.Forms.TreeNode("SITE $siteCode")
    [void]$tree.Nodes.Add($root)

    $roleRows = $Script:Results | Where-Object { $_.Category -eq 'Site System Role' -and $_.Check -eq 'Role Discovered' }
    $servers = $roleRows | Group-Object TargetServer | Sort-Object Name
    foreach ($server in $servers) {
        $serverNode = New-Object System.Windows.Forms.TreeNode($server.Name)
        [void]$root.Nodes.Add($serverNode)
        foreach ($roleItem in ($server.Group | Sort-Object Role)) {
            [void]$serverNode.Nodes.Add((New-Object System.Windows.Forms.TreeNode($roleItem.Role)))
        }
    }
    $tree.ExpandAll()
}

function Update-Summary {
    $critical = ($Script:Results | Where-Object Status -eq 'Critical' | Measure-Object).Count
    $warning = ($Script:Results | Where-Object Status -eq 'Warning' | Measure-Object).Count
    $healthy = ($Script:Results | Where-Object Status -eq 'Healthy' | Measure-Object).Count
    $info = ($Script:Results | Where-Object Status -eq 'Info' | Measure-Object).Count
    $servers = ($Script:Results | Where-Object { $_.Category -eq 'Site System Role' } | Select-Object -ExpandProperty TargetServer -Unique | Measure-Object).Count
    $roles = ($Script:Results | Where-Object { $_.Category -eq 'Site System Role' } | Measure-Object).Count
    $lblSummary.Text = "Healthy: $healthy | Warnings: $warning | Critical: $critical | Info: $info | Servers: $servers | Role instances: $roles"
}

function Run-DiscoveryButtonClick {
    try {
        $btnDiscovery.Enabled = $false
        $btnExport.Enabled = $false
        $Script:AssessmentId = ([guid]::NewGuid()).Guid.ToUpper()
        Ensure-OutputFolders
        $Script:CurrentLogFile = Join-Path $Script:LogPath "ConfigMgr_Assessment_$((Get-Date).ToString('yyyyMMdd_HHmmss'))_$($Script:AssessmentId).log"
        $Script:CurrentLogFile = Initialize-LogFile -RequestedLogFile $Script:CurrentLogFile
        $Script:Results.Clear()
        $txtLog.Clear()
        $grid.Rows.Clear()
        $tree.Nodes.Clear()
        $lblAssessmentId.Text = "Assessment ID: $($Script:AssessmentId)"
        $lblCsv.Text = 'CSV: not exported yet'
        Set-UiProgress 0 'Starting'
        Write-UiLog '============================================================'
        Write-UiLog 'ConfigMgr Assessment Tool by J. Maia - Discovery started'
        Write-UiLog "Log file: $Script:CurrentLogFile"

        $siteCode = $txtSiteCode.Text.Trim()
        $provider = $txtProvider.Text.Trim()

        $discoveryResults = Invoke-ConfigMgrDiscovery -SiteCode $siteCode -ProviderServer $provider -AssessmentId $Script:AssessmentId -LogCallback { param($m) Write-UiLog $m } -ProgressCallback { param($p,$a) Set-UiProgress $p $a }
        foreach ($item in $discoveryResults) { $Script:Results.Add($item) }

        Refresh-ResultsGrid
        Refresh-TopologyTree
        Update-Summary

        $Script:LastCsvFile = Export-AssessmentCsv -Results $Script:Results -OutputFolder $Script:CsvPath -AssessmentId $Script:AssessmentId
        $lblCsv.Text = "CSV: $Script:LastCsvFile"
        $btnExport.Enabled = $true
        Write-UiLog "CSV exported automatically: $Script:LastCsvFile"
        Write-UiLog 'Discovery finished.'
        Set-UiProgress 100 'Done'
    }
    catch {
        Write-UiLog "UNHANDLED ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Discovery failed: $($_.Exception.Message)", 'ConfigMgr Assessment Tool by J. Maia', 'OK', 'Error') | Out-Null
    }
    finally {
        $btnDiscovery.Enabled = $true
    }
}

function Export-ButtonClick {
    try {
        if ($Script:Results.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('There are no results to export. Run Discovery first.', 'Export CSV', 'OK', 'Information') | Out-Null
            return
        }
        $path = Export-AssessmentCsv -Results $Script:Results -OutputFolder $Script:CsvPath -AssessmentId $Script:AssessmentId
        $Script:LastCsvFile = $path
        $lblCsv.Text = "CSV: $path"
        Write-UiLog "CSV exported: $path"
        [System.Windows.Forms.MessageBox]::Show("CSV exported:`n$path", 'Export CSV', 'OK', 'Information') | Out-Null
    } catch {
        Write-UiLog "EXPORT ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)", 'Export CSV', 'OK', 'Error') | Out-Null
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'ConfigMgr Assessment Tool by J. Maia - v1.0.4-alpha Phase 1'
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1050, 650)

$fontNormal = New-Object System.Drawing.Font('Segoe UI', 9)
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$form.Font = $fontNormal

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'ConfigMgr Assessment Tool by J. Maia'
$lblTitle.Font = $fontTitle
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(15, 12)
$form.Controls.Add($lblTitle)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = 'Version 1.0.3-alpha | Phase 1 Fixed MVP'
$lblVersion.AutoSize = $true
$lblVersion.Location = New-Object System.Drawing.Point(18, 43)
$form.Controls.Add($lblVersion)

$lblAssessmentId = New-Object System.Windows.Forms.Label
$lblAssessmentId.Text = "Assessment ID: $Script:AssessmentId"
$lblAssessmentId.AutoSize = $true
$lblAssessmentId.Location = New-Object System.Drawing.Point(18, 68)
$form.Controls.Add($lblAssessmentId)

$lblSiteCode = New-Object System.Windows.Forms.Label
$lblSiteCode.Text = 'Site Code:'
$lblSiteCode.AutoSize = $true
$lblSiteCode.Location = New-Object System.Drawing.Point(20, 105)
$form.Controls.Add($lblSiteCode)

$txtSiteCode = New-Object System.Windows.Forms.TextBox
$txtSiteCode.Location = New-Object System.Drawing.Point(95, 101)
$txtSiteCode.Size = New-Object System.Drawing.Size(95, 25)
$txtSiteCode.CharacterCasing = 'Upper'
$form.Controls.Add($txtSiteCode)

$lblProvider = New-Object System.Windows.Forms.Label
$lblProvider.Text = 'SMS Provider:'
$lblProvider.AutoSize = $true
$lblProvider.Location = New-Object System.Drawing.Point(210, 105)
$form.Controls.Add($lblProvider)

$txtProvider = New-Object System.Windows.Forms.TextBox
$txtProvider.Location = New-Object System.Drawing.Point(305, 101)
$txtProvider.Size = New-Object System.Drawing.Size(330, 25)
$form.Controls.Add($txtProvider)

$btnDiscovery = New-Object System.Windows.Forms.Button
$btnDiscovery.Text = 'Run Discovery'
$btnDiscovery.Location = New-Object System.Drawing.Point(655, 99)
$btnDiscovery.Size = New-Object System.Drawing.Size(130, 30)
$btnDiscovery.Add_Click({ Run-DiscoveryButtonClick })
$form.Controls.Add($btnDiscovery)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export CSV'
$btnExport.Location = New-Object System.Drawing.Point(795, 99)
$btnExport.Size = New-Object System.Drawing.Size(110, 30)
$btnExport.Enabled = $false
$btnExport.Add_Click({ Export-ButtonClick })
$form.Controls.Add($btnExport)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = 'Exit'
$btnExit.Location = New-Object System.Drawing.Point(915, 99)
$btnExit.Size = New-Object System.Drawing.Size(85, 30)
$btnExit.Add_Click({ $form.Close() })
$form.Controls.Add($btnExit)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(20, 145)
$progress.Size = New-Object System.Drawing.Size(980, 20)
$progress.Minimum = 0
$progress.Maximum = 100
$form.Controls.Add($progress)

$lblCurrentTask = New-Object System.Windows.Forms.Label
$lblCurrentTask.Text = 'Current task: Ready'
$lblCurrentTask.AutoSize = $true
$lblCurrentTask.Location = New-Object System.Drawing.Point(20, 170)
$form.Controls.Add($lblCurrentTask)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(20, 200)
$tabs.Size = New-Object System.Drawing.Size(1120, 455)
$tabs.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($tabs)

$tabResults = New-Object System.Windows.Forms.TabPage
$tabResults.Text = 'Results'
$tabs.TabPages.Add($tabResults)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
[void]$grid.Columns.Add('Status','Status')
[void]$grid.Columns.Add('Category','Category')
[void]$grid.Columns.Add('Check','Check')
[void]$grid.Columns.Add('TargetServer','Target Server')
[void]$grid.Columns.Add('Role','Role')
[void]$grid.Columns.Add('Finding','Finding')
$tabResults.Controls.Add($grid)

$tabTopology = New-Object System.Windows.Forms.TabPage
$tabTopology.Text = 'Topology'
$tabs.TabPages.Add($tabTopology)
$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = 'Fill'
$tabTopology.Controls.Add($tree)

$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Execution Log'
$tabs.TabPages.Add($tabLog)
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Dock = 'Fill'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabLog.Controls.Add($txtLog)

$tabModules = New-Object System.Windows.Forms.TabPage
$tabModules.Text = 'Future Modules'
$tabs.TabPages.Add($tabModules)
$futureText = New-Object System.Windows.Forms.TextBox
$futureText.Multiline = $true
$futureText.Dock = 'Fill'
$futureText.ReadOnly = $true
$futureText.Text = @'
Planned modules for next phases:

[ ] Core Health
[ ] SCCM Component Status
[ ] Role Assessment: MP / DP / SUP / Reporting / Service Connection Point
[ ] SUP / WSUS Assessment
[ ] Distribution Content Status
[ ] SQL Assessment (separate permissions-sensitive module)

Phase 1 acceptance criteria:
- Run Discovery button must visibly execute.
- Progress bar must move.
- Log tab must show each action in real time.
- Results tab must show validation, connectivity, SMS Provider and role discovery results.
- Topology tab must show discovered site systems and roles.
- CSV must be created under Output\CSV.
- Log must be created under Output\Logs.
'@
$tabModules.Controls.Add($futureText)

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Text = 'Healthy: 0 | Warnings: 0 | Critical: 0 | Info: 0 | Servers: 0 | Role instances: 0'
$lblSummary.AutoSize = $true
$lblSummary.Location = New-Object System.Drawing.Point(20, 665)
$lblSummary.Anchor = 'Bottom,Left'
$form.Controls.Add($lblSummary)

$lblCsv = New-Object System.Windows.Forms.Label
$lblCsv.Text = 'CSV: not exported yet'
$lblCsv.AutoSize = $true
$lblCsv.Location = New-Object System.Drawing.Point(20, 690)
$lblCsv.Anchor = 'Bottom,Left'
$form.Controls.Add($lblCsv)

Write-UiLog 'Application started. Fill Site Code and SMS Provider, then click Run Discovery.'
[void]$form.ShowDialog()
