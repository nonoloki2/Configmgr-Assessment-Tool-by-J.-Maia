Set-StrictMode -Version Latest

function New-AssessmentResult {
    param(
        [string]$AssessmentId,
        [string]$SiteCode,
        [string]$ProviderServer,
        [string]$Module = 'Discovery',
        [string]$Category,
        [string]$Check,
        [string]$TargetServer = '',
        [string]$Role = '',
        [ValidateSet('Healthy','Warning','Critical','NotApplicable','UnableToCheck','Info')]
        [string]$Status = 'Info',
        [ValidateSet('None','Low','Medium','High','Critical')]
        [string]$Severity = 'None',
        [string]$Finding = '',
        [string]$Recommendation = '',
        [string]$Evidence = '',
        [string]$Source = ''
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
        Check          = $Check
        Status         = $Status
        Severity       = $Severity
        Finding        = $Finding
        Recommendation = $Recommendation
        Evidence       = $Evidence
        Source         = $Source
    }
}

function Resolve-ToolRoot {
    $modulePath = Split-Path -Parent $PSScriptRoot
    return $modulePath
}

Export-ModuleMember -Function New-AssessmentResult, Resolve-ToolRoot
