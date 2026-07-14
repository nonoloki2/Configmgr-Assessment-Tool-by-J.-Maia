<#
 ConfigMgr Assessment Tool by J. Maia
 Version 2.0.9-alpha | Build 0025
 Phase: Visible Native Window Controls Fix
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# WPF requires STA. Relaunch in STA if needed.
try {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        $psExe = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
        Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',('"{0}"' -f $PSCommandPath)) -WorkingDirectory $script:AppRoot | Out-Null
        return
    }
} catch { }

Set-Location -LiteralPath $script:AppRoot

$requiredDirs = @(
    'Output','Output\Logs','Output\CSV','Output\Reports','Config','KnowledgeBase',
    'Modules','Modules\Core','Modules\Engines','Modules\UI','Data','Data\History'
)
foreach ($d in $requiredDirs) {
    $p = Join-Path $script:AppRoot $d
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$script:CATMissingModules = New-Object System.Collections.Generic.List[string]
function Import-CATOptionalModule {
    param([Parameter(Mandatory)][string]$RelativePath)
    $modulePath = Join-Path $script:AppRoot $RelativePath
    if (Test-Path -LiteralPath $modulePath) {
        Import-Module $modulePath -Force -ErrorAction Stop
    } else {
        [void]$script:CATMissingModules.Add($RelativePath)
    }
}

# Import original modules when they exist. Missing engine/core modules no longer prevent the UI from opening.
Import-CATOptionalModule 'Modules\Core\Common.psm1'
Import-CATOptionalModule 'Modules\Core\Logging.psm1'
Import-CATOptionalModule 'Modules\Core\Export.psm1'
Import-CATOptionalModule 'Modules\Engines\DiscoveryEngine.psm1'
Import-CATOptionalModule 'Modules\Engines\CoreHealthEngine.psm1'
Import-CATOptionalModule 'Modules\Engines\ManagementPointEngine.psm1'
Import-CATOptionalModule 'Modules\Engines\RuleEngine.psm1'
Import-CATOptionalModule 'Modules\Engines\ReportEngine.psm1'
Import-CATOptionalModule 'Modules\UI\MainWindow.psm1'

if (-not (Get-Command Get-CATSettings -ErrorAction SilentlyContinue)) {
    function Get-CATSettings {
        param([string]$Path,[string]$AppRoot)
        if (Test-Path -LiteralPath $Path) {
            try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { }
        }
        return [pscustomobject]@{ AppRoot = $AppRoot; Version = '2.0.9-alpha'; Build = '0025' }
    }
}

if (-not (Get-Command New-CATAssessmentSession -ErrorAction SilentlyContinue)) {
    function New-CATAssessmentSession {
        param([string]$AppRoot,[object]$Settings)
        $assessmentId = 'CAT-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        $logFile = Join-Path $AppRoot ('Output\Logs\{0}.log' -f $assessmentId)
        return [pscustomobject]@{
            AppRoot = $AppRoot
            Settings = $Settings
            AssessmentID = $assessmentId
            StartTime = Get-Date
            LogFile = $logFile
            Results = New-Object System.Collections.ArrayList
            Inventory = [pscustomobject]@{
                Site = $null
                Servers = @()
                Roles = @()
                Counts = [ordered]@{}
                SQL = $null
                Boundaries = @()
                BoundaryGroups = @()
                CoreHealth = $null
                HealthScore = $null
            }
            LastCsvPath = $null
            LastHtmlPath = $null
        }
    }
}

if (-not (Get-Command Initialize-CATLogger -ErrorAction SilentlyContinue)) {
    function Initialize-CATLogger { param([object]$Session)
        $folder = Split-Path -Parent $Session.LogFile
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        'ConfigMgr Assessment Tool log initialized.' | Out-File -FilePath $Session.LogFile -Encoding UTF8
    }
}

if (-not (Get-Command Write-CATLog -ErrorAction SilentlyContinue)) {
    function Write-CATLog { param([object]$Session,[string]$Level='INFO',[string]$Message,[string]$Category='General')
        $line = '{0} [{1}] [{2}] {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Level,$Category,$Message
        Add-Content -LiteralPath $Session.LogFile -Value $line -Encoding UTF8
    }
}

if (-not (Get-Command Invoke-CATDiscovery -ErrorAction SilentlyContinue)) {
    function Invoke-CATDiscovery {
        param([object]$Session,[string]$SiteCode,[string]$ProviderServer,[scriptblock]$ProgressCallback,[scriptblock]$LogCallback)
        & $ProgressCallback 100 'Discovery engine module not present'
        & $LogCallback 'DiscoveryEngine.psm1 was not included in this package. UI validation mode only.' 'WARN'
        [void]$Session.Results.Add([pscustomobject]@{
            Status='Warning'; Severity='Warning'; Module='Startup'; Category='Modules'; Check='Missing module'; Target='DiscoveryEngine.psm1'; Role='N/A'; Value='Not found';
            Finding='The UI opened successfully, but the assessment engine modules were not included in the uploaded files/package.';
            Impact='Assessment cannot run until the original Modules\Core and Modules\Engines files are added.';
            Evidence=('Missing modules: ' + ($script:CATMissingModules -join ', ')); RuleId='CAT-MODULES-001'
        })
        $Session.Inventory.Counts.Servers = 0
        $Session.Inventory.Counts.RoleInstances = 0
    }
}

if (-not (Get-Command Invoke-CATCoreHealth -ErrorAction SilentlyContinue)) {
    function Invoke-CATCoreHealth { param([object]$Session,[scriptblock]$ProgressCallback,[scriptblock]$LogCallback)
        & $ProgressCallback 100 'Core Health skipped - module not present'
        & $LogCallback 'CoreHealthEngine.psm1 was not included. Skipping Core Health.' 'WARN'
        return [pscustomobject]@{ Servers = 0; Warning = 0; Critical = 0 }
    }
}

if (-not (Get-Command Invoke-CATManagementPointAssessment -ErrorAction SilentlyContinue)) {
    function Invoke-CATManagementPointAssessment { param([object]$Session,[scriptblock]$ProgressCallback,[scriptblock]$LogCallback)
        & $ProgressCallback 100 'Management Point skipped - module not present'
        & $LogCallback 'ManagementPointEngine.psm1 was not included. Skipping MP assessment.' 'WARN'
        return [pscustomobject]@{ ManagementPoints = 0; Warning = 0; Critical = 0 }
    }
}

if (-not (Get-Command Export-CATCsv -ErrorAction SilentlyContinue)) {
    function Export-CATCsv { param([object]$Session)
        $path = Join-Path $Session.AppRoot ('Output\CSV\{0}_Results.csv' -f $Session.AssessmentID)
        @($Session.Results) | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
        return $path
    }
}

if (-not (Get-Command Export-CATHtmlReport -ErrorAction SilentlyContinue)) {
    function Export-CATHtmlReport { param([object]$Session)
        $path = Join-Path $Session.AppRoot ('Output\Reports\{0}_Report.html' -f $Session.AssessmentID)
        $body = @($Session.Results) | ConvertTo-Html -Title 'ConfigMgr Assessment Tool'
        $body | Out-File -LiteralPath $path -Encoding UTF8
        return $path
    }
}

$settingsPath = Join-Path $script:AppRoot 'Config\Settings.json'
$settings = Get-CATSettings -Path $settingsPath -AppRoot $script:AppRoot
$session = New-CATAssessmentSession -AppRoot $script:AppRoot -Settings $settings
Initialize-CATLogger -Session $session
Write-CATLog -Session $session -Level 'INFO' -Message 'Application started.' -Category 'Startup'

if ($script:CATMissingModules.Count -gt 0) {
    Write-CATLog -Session $session -Level 'WARN' -Category 'Startup' -Message ('Missing optional modules: ' + ($script:CATMissingModules -join ', '))
}

Show-CATMainWindow -Session $session
