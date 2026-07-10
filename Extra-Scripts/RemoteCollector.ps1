#requires -Version 5.1
[CmdletBinding()]
param(
    [int]$DaysBack = 7
)

$ErrorActionPreference = 'Stop'
$FrebRoot = 'C:\inetpub\logs\FailedReqLogFiles'
$StartDate = (Get-Date).AddDays(-$DaysBack)

function Normalize-Name {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return ($Name -replace '[^A-Za-z0-9]','').ToLowerInvariant()
}

function Get-Attr {
    param(
        [System.Xml.XmlElement]$Root,
        [string[]]$Names
    )

    $wanted = @($Names | ForEach-Object { Normalize-Name $_ })

    foreach ($a in $Root.Attributes) {
        if ((Normalize-Name $a.LocalName) -in $wanted) {
            return $a.Value
        }
    }

    return $null
}

function Get-HttpError {
    param(
        [string]$StatusCode,
        [string]$SubStatusCode,
        [string]$TriggerStatus
    )

    $StatusCode = "$StatusCode".Trim()
    $SubStatusCode = "$SubStatusCode".Trim()
    $TriggerStatus = "$TriggerStatus".Trim()

    if ($TriggerStatus -match '^(401|500)(?:\.\d+)?$') {
        return $TriggerStatus
    }

    if ($StatusCode -match '^(401|500)$' -and $SubStatusCode -match '^\d+$' -and $SubStatusCode -ne '0') {
        return "$StatusCode.$SubStatusCode"
    }

    if ($StatusCode -match '^(401|500)(?:\.\d+)?$') {
        return $StatusCode
    }

    return $null
}

function Get-UrlInfo {
    param([string]$Url)

    $package = $null
    $file = $null

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return [PSCustomObject]@{ PackageID = $null; ArquivoComErro = $null }
    }

    try {
        $decoded = [System.Net.WebUtility]::HtmlDecode($Url)
        $decoded = [System.Uri]::UnescapeDataString($decoded)
    }
    catch {
        $decoded = $Url
    }

    if ($decoded -match '(?i)/ccmtokenauth_sms_dp_smspkg\$/([^/?#]+)/([^?#]+)') {
        $package = $Matches[1]
        $relative = ($Matches[2] -split '\?')[0].TrimEnd('/')
        $file = [System.IO.Path]::GetFileName(($relative -replace '/', '\'))
    }
    else {
        try {
            $uri = New-Object System.Uri($decoded)
            $file = [System.IO.Path]::GetFileName($uri.AbsolutePath)
        }
        catch {
            $clean = ($decoded -split '\?')[0].TrimEnd('/')
            $file = [System.IO.Path]::GetFileName(($clean -replace '/', '\'))
        }
    }

    return [PSCustomObject]@{
        PackageID = $package
        ArquivoComErro = $file
    }
}

function Emit-JsonLine {
    param(
        [string]$Prefix,
        [object]$Object
    )

    $json = $Object | ConvertTo-Json -Compress -Depth 5
    [Console]::Out.WriteLine($Prefix + $json)
}

$read = 0
$found = 0
$invalid = 0

try {
    if (-not (Test-Path -LiteralPath $FrebRoot -PathType Container)) {
        Emit-JsonLine 'FREB_SUMMARY|' ([PSCustomObject]@{
            Status = 'FrebPathNotFound'
            Details = "Pasta não encontrada: $FrebRoot"
            XmlFilesRead = 0
            ErrorsFound = 0
            InvalidXmlCount = 0
            FrebPath = $FrebRoot
        })
        exit 0
    }

    $files = @(
        Get-ChildItem -LiteralPath $FrebRoot -Filter 'fr*.xml' -File -Recurse |
            Where-Object { $_.LastWriteTime -ge $StartDate }
    )

    foreach ($file in $files) {
        try {
            [xml]$xml = Get-Content -LiteralPath $file.FullName -Raw
            $root = $xml.DocumentElement
            if (-not $root) { throw 'XML sem elemento raiz.' }

            $read++

            $url = Get-Attr $root @('URL')
            $appPool = Get-Attr $root @('APP_POOL_ID','APPPOOLID','APP_POOL','APPLICATION_POOL')
            $statusCode = Get-Attr $root @('STATUS_CODE','STATUSCODE','FINAL_STATUS')
            $subStatusCode = Get-Attr $root @('SUB_STATUS_CODE','SUBSTATUSCODE')
            $triggerStatus = Get-Attr $root @('TRIGGER_STATUS','TRIGGERSTATUS')
            $failureReason = Get-Attr $root @('FAILURE_REASON','FAILUREREASON')
            $siteId = Get-Attr $root @('SITE_ID','SITEID')
            $activityId = Get-Attr $root @('ACTIVITY_ID','ACTIVITYID')
            $timeTaken = Get-Attr $root @('TIME_TAKEN','TIMETAKEN')

            $errorCode = Get-HttpError $statusCode $subStatusCode $triggerStatus
            if (-not $errorCode) { continue }

            $baseCode = ($errorCode -split '\.')[0]
            if ($baseCode -notin @('401','500')) { continue }

            $info = Get-UrlInfo $url
            $found++

            Emit-JsonLine 'FREB_RESULT|' ([PSCustomObject]@{
                Hostname = $env:COMPUTERNAME
                AppPool = $appPool
                Erro = $errorCode
                PackageID = $info.PackageID
                ArquivoComErro = $info.ArquivoComErro
                URL = $url
                FailureReason = $failureReason
                StatusCode = $statusCode
                SubStatusCode = $subStatusCode
                TriggerStatus = $triggerStatus
                SiteIIS = $siteId
                DataLog = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                TempoMS = $timeTaken
                ActivityID = $activityId
                ArquivoXML = $file.FullName
            })
        }
        catch {
            $invalid++
        }
    }

    Emit-JsonLine 'FREB_SUMMARY|' ([PSCustomObject]@{
        Status = 'Success'
        Details = 'Análise concluída'
        XmlFilesRead = $read
        ErrorsFound = $found
        InvalidXmlCount = $invalid
        FrebPath = $FrebRoot
    })
}
catch {
    Emit-JsonLine 'FREB_SUMMARY|' ([PSCustomObject]@{
        Status = 'Failed'
        Details = $_.Exception.Message
        XmlFilesRead = $read
        ErrorsFound = $found
        InvalidXmlCount = $invalid
        FrebPath = $FrebRoot
    })
    exit 1
}
