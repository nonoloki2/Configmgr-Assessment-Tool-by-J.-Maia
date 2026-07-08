function Get-CATSettings {
    [CmdletBinding()]
    param([string]$Path,[string]$AppRoot)
    if (-not (Test-Path -LiteralPath $Path)) {
        $default = [ordered]@{
            ApplicationName = 'ConfigMgr Assessment Tool by J. Maia'
            Version = '2.0.5-alpha'
            Build = '0018'
            Theme = 'Light'
            TimeoutSeconds = 30
            MaxThreads = 8
            ExportFolder = 'Output'
            LogLevel = 'INFO'
            Language = 'en-US'
        }
        $default | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Get-CATAssessmentPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot)
    $path = Join-Path $AppRoot 'Config\AssessmentPolicy.json'
    if (-not (Test-Path -LiteralPath $path)) {
        $default = [ordered]@{
            Uptime = [ordered]@{ HealthyMaxDays = 37; WarningMaxDays = 59; CriticalMinDays = 60 }
            DiskFree = [ordered]@{ HealthyMinPercent = 20; WarningMinPercent = 10; CriticalBelowPercent = 10; CriticalBelowGB = 10; WarningBelowGB = 20 }
            MemoryUsage = [ordered]@{ HealthyMaxPercent = 80; WarningMaxPercent = 90; CriticalAbovePercent = 90 }
            CpuUsage = [ordered]@{ HealthyMaxPercent = 80; WarningMaxPercent = 90; CriticalAbovePercent = 90 }
            Ping = [ordered]@{ WarningLatencyMs = 100; CriticalLatencyMs = 250; PingCount = 4 }
        }
        $default | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function New-CATAssessmentSession {
    [CmdletBinding()]
    param([string]$AppRoot,[object]$Settings)
    $id = [guid]::NewGuid().Guid.ToUpperInvariant()
    $now = Get-Date
    [pscustomobject]@{
        AssessmentID = $id
        AppRoot = $AppRoot
        Settings = $Settings
        Policy = Get-CATAssessmentPolicy -AppRoot $AppRoot
        StartTime = $now
        Results = New-Object System.Collections.ArrayList
        Inventory = [ordered]@{
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
        LogFile = $null
        LastCsvPath = $null
        LastHtmlPath = $null
    }
}

function New-CATResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AssessmentID,
        [string]$Module = 'Discovery',
        [string]$Category = 'General',
        [string]$Check = '',
        [string]$Target = '',
        [string]$Role = '',
        [string]$Value = '',
        [ValidateSet('Healthy','Warning','Critical','Info','NotApplicable','UnableToCheck')][string]$Status = 'Info',
        [string]$Severity = 'Info',
        [string]$Impact = '',
        [string]$Finding = '',
        [string]$Recommendation = '',
        [string]$Evidence = '',
        [string]$Source = '',
        [string]$RuleId = '',
        [double]$DurationSeconds = 0
    )
    [pscustomobject]@{
        AssessmentID = $AssessmentID
        AssessmentDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Module = $Module
        Category = $Category
        Check = $Check
        Target = $Target
        Role = $Role
        Value = $Value
        Status = $Status
        Severity = $Severity
        Impact = $Impact
        Finding = $Finding
        Recommendation = $Recommendation
        Evidence = $Evidence
        Source = $Source
        RuleId = $RuleId
        DurationSeconds = $DurationSeconds
        ToolVersion = '2.0.5-alpha'
        Build = '0018'
    }
}

function Add-CATResult {
    [CmdletBinding()]
    param([object]$Session,[object]$Result)
    [void]$Session.Results.Add($Result)
    return $Result
}

Export-ModuleMember -Function *
