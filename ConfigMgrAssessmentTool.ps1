<#
 ConfigMgr Assessment Tool by J. Maia
 Version 2.0.3-alpha | Build 0016
 Phase: MP Connectivity, Services and IIS Prerequisites
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$requiredDirs = @(
    'Output','Output\Logs','Output\CSV','Output\Reports','Config','KnowledgeBase','Modules','Modules\Core','Modules\Engines','Modules\UI','Data','Data\History'
)
foreach ($d in $requiredDirs) {
    $p = Join-Path $script:AppRoot $d
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

Import-Module (Join-Path $script:AppRoot 'Modules\Core\Common.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Core\Logging.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Core\Export.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Engines\DiscoveryEngine.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Engines\CoreHealthEngine.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Engines\ManagementPointEngine.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Engines\RuleEngine.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\Engines\ReportEngine.psm1') -Force
Import-Module (Join-Path $script:AppRoot 'Modules\UI\MainWindow.psm1') -Force

$settingsPath = Join-Path $script:AppRoot 'Config\Settings.json'
$settings = Get-CATSettings -Path $settingsPath -AppRoot $script:AppRoot
$session = New-CATAssessmentSession -AppRoot $script:AppRoot -Settings $settings
Initialize-CATLogger -Session $session
Write-CATLog -Session $session -Level 'INFO' -Message 'Application started.' -Category 'Startup'

Show-CATMainWindow -Session $session
