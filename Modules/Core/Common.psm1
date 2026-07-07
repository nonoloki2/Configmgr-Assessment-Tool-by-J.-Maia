function Get-CATSettings {
    [CmdletBinding()]
    param([string]$Path,[string]$AppRoot)
    if (-not (Test-Path -LiteralPath $Path)) {
        $default = [ordered]@{
            ApplicationName = 'ConfigMgr Assessment Tool by J. Maia'
            Version = '1.1.1-alpha'
            Build = '0006'
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

function New-CATAssessmentSession {
    [CmdletBinding()]
    param([string]$AppRoot,[object]$Settings)
    $id = [guid]::NewGuid().Guid.ToUpperInvariant()
    $now = Get-Date
    [pscustomobject]@{
        AssessmentID = $id
        AppRoot = $AppRoot
        Settings = $Settings
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
        }
        LogFile = $null
        LastCsvPath = $null
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
        [ValidateSet('Healthy','Warning','Critical','Info','NotApplicable','UnableToCheck')][string]$Status = 'Info',
        [string]$Severity = 'Info',
        [string]$Finding = '',
        [string]$Recommendation = '',
        [string]$Evidence = '',
        [string]$Source = '',
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
        Status = $Status
        Severity = $Severity
        Finding = $Finding
        Recommendation = $Recommendation
        Evidence = $Evidence
        Source = $Source
        DurationSeconds = $DurationSeconds
        ToolVersion = '1.1.1-alpha'
        Build = '0006'
    }
}

function Add-CATResult {
    [CmdletBinding()]
    param([object]$Session,[object]$Result)
    [void]$Session.Results.Add($Result)
    return $Result
}

Export-ModuleMember -Function *
