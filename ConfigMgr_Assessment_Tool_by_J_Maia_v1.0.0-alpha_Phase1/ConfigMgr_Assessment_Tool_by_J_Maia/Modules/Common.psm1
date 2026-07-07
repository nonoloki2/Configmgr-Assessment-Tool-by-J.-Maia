function New-AssessmentResult {
    [CmdletBinding()]
    param(
        [string]$AssessmentId,
        [string]$SiteCode,
        [string]$ProviderServer,
        [string]$TargetServer,
        [string]$Module,
        [string]$Category,
        [string]$CheckName,
        [ValidateSet('Healthy','Warning','Critical','NotApplicable','UnableToCheck','Info')]
        [string]$Status = 'Info',
        [ValidateSet('None','Low','Medium','High','Critical')]
        [string]$Severity = 'None',
        [string]$Finding,
        [string]$Recommendation,
        [string]$Evidence,
        [string]$Source = 'ConfigMgr Assessment Tool by J. Maia',
        [string]$Role,
        [string]$LogFile,
        [datetime]$LastErrorTime
    )

    [pscustomobject]@{
        AssessmentDate = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        AssessmentId   = $AssessmentId
        SiteCode       = $SiteCode
        ProviderServer = $ProviderServer
        TargetServer   = $TargetServer
        Role           = $Role
        Module         = $Module
        Category       = $Category
        CheckName      = $CheckName
        Status         = $Status
        Severity       = $Severity
        Finding        = $Finding
        Recommendation = $Recommendation
        Evidence       = $Evidence
        Source         = $Source
        LogFile        = $LogFile
        LastErrorTime  = if ($LastErrorTime) { $LastErrorTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
    }
}

function Ensure-Directory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

Export-ModuleMember -Function New-AssessmentResult, Ensure-Directory
