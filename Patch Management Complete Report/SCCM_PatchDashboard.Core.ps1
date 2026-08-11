# Release 2.8 - Top Error Description Fix + Preferred Distribution Points
#requires -Version 5.1
<#
.SYNOPSIS
    SCCM Monthly Patch Dashboard - Prototype v2.4

.DESCRIPTION
    WPF interface that reads a Software Update Deployment from the SCCM SMS Provider,
    enriches device data, optionally resolves UPNs in Active Directory and checks
    pending reboot remotely. It exports:
      - Dashboard.html
      - Devices_Success.html
      - Devices_InProgress.html
      - Devices_Error.html
      - Devices_Unknown.html
      - DeploymentDetails.csv
      - Generation.log

    Each donut segment, metric card and legend item opens the corresponding device
    list in a new browser tab.

.NOTES
    Run on a Windows machine with network access to the SMS Provider.
    For real SCCM data, the account needs read permission in Configuration Manager.
    AD UPN resolution requires the ActiveDirectory PowerShell module.
    Pending reboot requires remote CIM/WMI access to root\ccm\ClientSDK.

    Prototype v2.4 includes Demo Mode so the interface and web report can be tested
    without connecting to SCCM.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

# Inicializacao que originalmente vivia na secao WPF (removida no fluxo
# headless). Sem isso, Read-ErrorKnowledgeBase falha sob Set-StrictMode
# na primeira chamada, porque a variavel nunca foi definida.
$script:ErrorKnowledgeBase = $null
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Web

function ConvertTo-HtmlSafe {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-JsString {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')
    return $s
}

function Convert-CimDate {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    if ($Value -is [datetime]) { return $Value }
    try { return [System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value) } catch {}
    try { return [datetime]$Value } catch { return $null }
}

function Format-DateValue {
    param($Value)
    $dt = Convert-CimDate $Value
    if ($null -eq $dt) { return '' }
    return $dt.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-StatusName {
    param([int]$StatusType)
    switch ($StatusType) {
        1 { 'Success' }
        2 { 'InProgress' }
        4 { 'Unknown' }
        5 { 'Error' }
        default { 'Unknown' }
    }
}

function Get-ErrorHex {
    param([UInt64]$Code)
    if ($Code -eq 0) { return '' }
    return ('0x{0:X8}' -f ([UInt32]$Code))
}

function Get-KnowledgeBasePath {
    $folder = Join-Path $PSScriptRoot 'KnowledgeBase'
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    return (Join-Path $folder 'ErrorKnowledgeBase.json')
}

function Read-ErrorKnowledgeBase {
    param([switch]$ForceReload)

    if (-not $ForceReload -and $script:ErrorKnowledgeBase) {
        return $script:ErrorKnowledgeBase
    }

    $path = Get-KnowledgeBasePath
    if (-not (Test-Path -LiteralPath $path)) {
        $script:ErrorKnowledgeBase = $null
        return $null
    }

    try {
        $kb = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $kb.schemaVersion -or -not $kb.errors) {
            throw 'The file does not contain schemaVersion and errors.'
        }
        $script:ErrorKnowledgeBase = $kb
        return $kb
    }
    catch {
        $script:ErrorKnowledgeBase = $null
        return $null
    }
}

function Get-ErrorKnowledgeEntry {
    param([UInt64]$Code)
    if ($Code -eq 0) { return $null }
    $hex = Get-ErrorHex $Code
    $kb = Read-ErrorKnowledgeBase
    if (-not $kb) { return $null }
    $property = $kb.errors.PSObject.Properties[$hex]
    if ($property) { return $property.Value }
    return $null
}

function Get-ErrorRecommendations {
    param([UInt64]$Code)
    if ($Code -eq 0) { return '' }

    $hex = Get-ErrorHex $Code
    $entry = Get-ErrorKnowledgeEntry -Code $Code
    $actions = @()

    if ($entry -and $entry.recommendations) {
        $actions = @($entry.recommendations | Sort-Object priority | Select-Object -First 3 | ForEach-Object {
            [string]$_.action
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    # Never leave Recommended Actions blank. The offline JSON remains the first
    # source, but these curated fallbacks keep troubleshooting useful when a
    # code is not yet present in the local knowledge base.
    if ($actions.Count -eq 0) {
        $specific = @{
            '0x80240008' = @(
                'Restart the Windows Update and BITS services, then trigger Software Updates Scan Cycle.',
                'Review WUAHandler.log and WindowsUpdate.log for the underlying Windows Update Agent failure.',
                'Reset Windows Update components if the scan continues to fail.'
            )
            '0x8024402C' = @(
                'Verify SUP/WSUS connectivity, proxy configuration, DNS resolution, and WinHTTP proxy settings.',
                'Review LocationServices.log, WUAHandler.log, and WSUSCtrl.log for HTTP or name-resolution failures.',
                'Confirm that the client boundary group has a valid SUP and that ports 8530/8531 are reachable.'
            )
            '0x80240035' = @(
                'Trigger Machine Policy Retrieval and Software Updates Scan Cycle on the affected client.',
                'Review WUAHandler.log, UpdatesDeployment.log, and UpdatesHandler.log for the failing operation.',
                'Reset the Windows Update Agent datastore if the error persists after policy refresh.'
            )
            '0x87D00319' = @(
                'Validate the application detection method against the installed product, file, registry, or MSI code.',
                'Review AppEnforce.log and AppDiscovery.log on the affected device.',
                'Correct the detection rule or installation command, then run Application Deployment Evaluation Cycle.'
            )
            '0x87D00650' = @(
                'Confirm that all required content is distributed successfully to the assigned Distribution Points.',
                'Review CAS.log, ContentTransferManager.log, DataTransferService.log, and LocationServices.log.',
                'Redistribute or validate content and confirm boundary-group content-location settings.'
            )
            '0x87D00664' = @(
                'Review UpdatesDeployment.log, UpdatesHandler.log, and WUAHandler.log for the enforcement failure.',
                'Confirm update applicability, maintenance-window availability, and restart requirements.',
                'Run policy retrieval and software-update evaluation cycles, then retry the deployment.'
            )
            '0x8007066A' = @(
                'Verify that the expected MSI product and version are installed on the device.',
                'Confirm that the patch or upgrade package targets the installed ProductCode and UpgradeCode.',
                'Review AppEnforce.log and the verbose MSI log, then repair or reinstall the base application if required.'
            )
            '0x80D02002' = @(
                'Confirm that the required update content is available on the assigned Distribution Point.',
                'Validate Delivery Optimization, BITS, proxy, firewall, and network connectivity.',
                'Review CAS.log, LocationServices.log, ContentTransferManager.log, and DataTransferService.log.'
            )
        }

        if ($specific.ContainsKey($hex)) {
            $actions = @($specific[$hex])
        }
        elseif ($hex -like '0x80244*') {
            $actions = @(
                'Verify client connectivity to the configured SUP/WSUS server and validate proxy settings.',
                'Review LocationServices.log and WUAHandler.log for HTTP, TLS, DNS, or authentication failures.',
                'Confirm boundary-group SUP assignment and WSUS/IIS health.'
            )
        }
        elseif ($hex -like '0x8024*') {
            $actions = @(
                'Trigger Software Updates Scan Cycle and review WUAHandler.log and WindowsUpdate.log.',
                'Verify that Windows Update, BITS, and ConfigMgr client services are running correctly.',
                'Reset Windows Update components and retry if policy refresh and scan do not resolve the issue.'
            )
        }
        elseif ($hex -like '0x87D0*') {
            $actions = @(
                'Review the ConfigMgr client log that corresponds to the deployment type and operation.',
                'Confirm policy, content location, applicability, detection rules, and maintenance-window availability.',
                'Refresh machine policy and rerun the relevant evaluation cycle before retrying.'
            )
        }
        elseif ($hex -like '0x800F*') {
            $actions = @(
                'Review CBS.log and DISM.log for servicing-stack and component-store details.',
                'Run DISM component-store health checks and confirm that the update is applicable.',
                'Verify servicing-stack prerequisites, free disk space, and source files before retrying.'
            )
        }
        elseif ($hex -like '0x8007*') {
            $actions = @(
                'Translate the underlying Win32 error and review the relevant ConfigMgr client log.',
                'Verify permissions, file paths, disk space, services, and prerequisites involved in the operation.',
                'Retry the operation with verbose logging after correcting the identified Windows error.'
            )
        }
        else {
            $actions = @(
                'Review the affected device logs and correlate the error with the last enforcement message.',
                'Refresh ConfigMgr machine policy and rerun the applicable evaluation or scan cycle.',
                'Validate content, connectivity, prerequisites, maintenance windows, and pending restart state.'
            )
        }
    }

    $actions = @($actions | Select-Object -First 3)
    $numbered = for ($i = 0; $i -lt $actions.Count; $i++) {
        '{0}. {1}' -f ($i + 1), $actions[$i]
    }
    return ($numbered -join '  ')
}

function Import-ErrorKnowledgeBaseFile {
    param([Parameter(Mandatory)][string]$SourcePath)

    $candidate = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $candidate.schemaVersion -or -not $candidate.knowledgeBaseVersion -or -not $candidate.errors) {
        throw 'Invalid knowledge-base file. Required fields: schemaVersion, knowledgeBaseVersion and errors.'
    }

    $errorCount = @($candidate.errors.PSObject.Properties).Count
    if ($errorCount -lt 1) { throw 'The knowledge-base file contains no error entries.' }

    foreach ($property in $candidate.errors.PSObject.Properties) {
        if ($property.Name -notmatch '^0x[0-9A-Fa-f]{8}$') {
            throw "Invalid error-code key: $($property.Name)"
        }
        if ([string]::IsNullOrWhiteSpace([string]$property.Value.description)) {
            throw "Missing description for $($property.Name)."
        }
        if (@($property.Value.recommendations).Count -gt 3) {
            throw "$($property.Name) contains more than three recommendations."
        }
    }

    $destination = Get-KnowledgeBasePath
    if (Test-Path -LiteralPath $destination) {
        $backup = '{0}.{1}.bak' -f $destination, (Get-Date -Format 'yyyyMMdd_HHmmss')
        Copy-Item -LiteralPath $destination -Destination $backup -Force
    }
    Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
    $null = Read-ErrorKnowledgeBase -ForceReload

    [pscustomobject]@{
        Version = [string]$candidate.knowledgeBaseVersion
        ErrorCount = $errorCount
        Destination = $destination
    }
}

function Get-ErrorDetail {
    param(
        [UInt64]$Code,
        [string]$LastEnforcementMessage,
        [string]$StatusDescription
    )

    if ($Code -eq 0) { return '' }

    $hex = Get-ErrorHex $Code

    $knowledgeEntry = Get-ErrorKnowledgeEntry -Code $Code
    if ($knowledgeEntry -and -not [string]::IsNullOrWhiteSpace([string]$knowledgeEntry.description)) {
        return [string]$knowledgeEntry.description
    }

    # Curated descriptions for common Windows Update, Delivery Optimization,
    # Configuration Manager, servicing and Windows Installer errors.
    $knownErrors = @{
        '0x80D02002' = 'Delivery Optimization: Download of a file saw no progress within the defined period.'
        '0x8007066A' = 'Windows Installer: The upgrade cannot be installed because the program to be upgraded may be missing, or the upgrade may target a different version. Verify that the product exists and that the correct update is being applied.'
        '0x87D00319' = 'Configuration Manager could not detect the application after installation, or the detection method returned an unexpected result.'
        '0x800F081F' = 'The source files required to repair or install the Windows component could not be found.'
        '0x800F081E' = 'The update package is not applicable to this computer.'
        '0x800F0922' = 'Windows could not complete the update. Common causes include insufficient system-reserved partition space or failure to connect to an update service.'
        '0x80244017' = 'Windows Update access was denied by the update service, commonly corresponding to HTTP 403.'
        '0x80244010' = 'Windows Update exceeded the maximum number of server round trips while searching for updates.'
        '0x80240022' = 'Windows Update failed to download or install all requested updates.'
        '0x80240437' = 'Windows Update could not complete the search because the update service returned an unexpected response.'
        '0x803D0010' = 'The configured proxy server could not be reached.'
        '0x80070057' = 'One or more parameters supplied to the operation are invalid.'
        '0x8007045B' = 'The operation was stopped because the system is shutting down or restarting.'
        '0x80073CF6' = 'The application package could not be registered.'
        '0x80D02003' = 'Delivery Optimization: The requested download job was not found.'
        '0x80D02004' = 'Delivery Optimization: The download job contains no files.'
        '0x80D0200D' = 'Delivery Optimization: No local file path was specified for the download.'
        '0x80D02010' = 'Delivery Optimization: The requested file is not available from any generated URL.'
    }

    if ($knownErrors.ContainsKey($hex)) {
        return $knownErrors[$hex]
    }

    # HRESULT_FROM_WIN32 values (0x8007xxxx) can usually be translated by Windows.
    $code32 = [UInt32]$Code
    if (($code32 -band 0xFFFF0000) -eq 0x80070000) {
        try {
            $win32Code = [int]($code32 -band 0x0000FFFF)
            $message = (New-Object System.ComponentModel.Win32Exception($win32Code)).Message
            if (-not [string]::IsNullOrWhiteSpace($message) -and $message -notmatch '^Unknown error') {
                return "Windows error $win32Code`: $message"
            }
        }
        catch {}
    }

    # Preserve a useful SCCM enforcement message only when it is more specific
    # than the generic status text that was previously repeated across columns.
    foreach ($candidate in @($LastEnforcementMessage, $StatusDescription)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $trimmed = $candidate.Trim()
        if ($trimmed -notmatch '^(Failed to install update\(s\)|Enforcement failed|Error|Unknown|Compliant|Compliance|Success|Succeeded|Installed|In Progress|InProgress|Not Required|Requirement Not Met)$') {
            return $trimmed
        }
    }

    return "No detailed description is currently mapped for $hex."
}

function Write-Log {
    param(
        [string]$Path,
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-SafeFileName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'Deployment' }
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $result = $Text
    foreach ($char in $invalid) { $result = $result.Replace([string]$char, '_') }
    return ($result -replace '\s+', '_').Trim('_')
}

function Get-SmsProviderData {
    param(
        [Parameter(Mandatory)][string]$ProviderServer,
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][int]$AssignmentID,
        [Parameter(Mandatory)][string]$LogPath
    )

    $namespace = "root\SMS\site_$SiteCode"
    Write-Log $LogPath "Connecting to SMS Provider '$ProviderServer' namespace '$namespace'."

    $summary = Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
        -Query "SELECT * FROM SMS_DeploymentSummary WHERE AssignmentID = $AssignmentID AND FeatureType = 5" `
        -OperationTimeoutSec 120 | Select-Object -First 1

    $assets = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
        -Query "SELECT * FROM SMS_SUMDeploymentAssetDetails WHERE AssignmentID = $AssignmentID" `
        -OperationTimeoutSec 300)

    if ($assets.Count -eq 0) {
        throw "No device status records were returned for AssignmentID $AssignmentID."
    }

    if ($null -eq $summary) {
        Write-Log $LogPath 'SMS_DeploymentSummary was empty; metadata will be taken from asset details.' 'WARN'
    }

    # Enrichment from SMS_CombinedDeviceResources in batches.
    $resourceIds = @($assets | ForEach-Object { [int]$_.ResourceID } | Sort-Object -Unique)
    $resourceMap = @{}
    $batchSize = 200

    for ($i = 0; $i -lt $resourceIds.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $resourceIds.Count - 1)
        $ids = ($resourceIds[$i..$end] -join ',')
        $query = "SELECT * FROM SMS_CombinedDeviceResources WHERE ResourceID IN ($ids)"
        try {
            $resources = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
                -Query $query -OperationTimeoutSec 180)
            foreach ($r in $resources) { $resourceMap[[int]$r.ResourceID] = $r }
        }
        catch {
            Write-Log $LogPath "CombinedDeviceResources batch failed: $($_.Exception.Message)" 'WARN'
        }
    }

    # OS name/build come from hardware inventory (SMS_G_System_OPERATING_SYSTEM), which is
    # the authoritative source. CombinedDeviceResources' OS-related fields vary between
    # ConfigMgr versions/sites and are often blank, so we query inventory directly instead.
    # Property suffixes (e.g. Caption00 vs Caption01) vary by inventory report revision, so
    # we select everything and match property names by prefix instead of hardcoding them.
    $osMap = @{}
    $osRowCount = 0
    $osPropsLogged = $false
    for ($i = 0; $i -lt $resourceIds.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $resourceIds.Count - 1)
        $ids = ($resourceIds[$i..$end] -join ',')
        $query = "SELECT * FROM SMS_G_System_OPERATING_SYSTEM WHERE ResourceID IN ($ids)"
        try {
            $osRows = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
                -Query $query -OperationTimeoutSec 180)

            if (-not $osPropsLogged -and $osRows.Count -gt 0) {
                $propNames = ($osRows[0].PSObject.Properties.Name -join ', ')
                Write-Log $LogPath "SMS_G_System_OPERATING_SYSTEM properties available: $propNames" 'INFO'
                $osPropsLogged = $true
            }

            foreach ($row in $osRows) {
                $osRowCount++
                $caption = ''
                $build = ''
                $version = ''
                $lastBoot = $null
                foreach ($p in $row.PSObject.Properties) {
                    if ($p.Name -match '^Caption' -and $p.Value -and -not $caption) { $caption = [string]$p.Value }
                    elseif ($p.Name -match '^BuildNumber' -and $p.Value -and -not $build) { $build = [string]$p.Value }
                    elseif ($p.Name -match '^Version' -and $p.Value -and -not $version) { $version = [string]$p.Value }
                    elseif ($p.Name -match '^LastBootUpTime' -and $p.Value -and -not $lastBoot) { $lastBoot = Convert-CimDate $p.Value }
                }
                $osMap[[int]$row.ResourceID] = [pscustomobject]@{
                    Caption        = $caption
                    BuildNumber    = $build
                    Version        = $version
                    LastBootUpTime = $lastBoot
                }
            }
        }
        catch {
            Write-Log $LogPath "SMS_G_System_OPERATING_SYSTEM batch failed: $($_.Exception.Message)" 'WARN'
        }
    }
    if ($osRowCount -eq 0) {
        Write-Log $LogPath 'SMS_G_System_OPERATING_SYSTEM returned no rows for any device. OS Name/Build will be blank. This usually means hardware inventory is not enabled/collected for this collection, or the OPERATING_SYSTEM inventory class is disabled in Client Settings.' 'WARN'
    }

    # Load boundary-group site systems once. Device-to-boundary-group membership is
    # read from SMS_CombinedDeviceResources when the site exposes one of the known
    # boundary-group properties. No per-device provider query is performed.
    $boundaryGroupNameToId = @{}
    $boundaryGroupDpMap = @{}
    try {
        $boundaryGroups = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
            -Query 'SELECT GroupID, Name FROM SMS_BoundaryGroup' -OperationTimeoutSec 120)
        foreach ($group in $boundaryGroups) {
            if (-not [string]::IsNullOrWhiteSpace([string]$group.Name)) {
                $boundaryGroupNameToId[[string]$group.Name] = [int]$group.GroupID
            }
        }

        $distributionPointServers = @{}
        try {
            $distributionPoints = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
                -Query 'SELECT * FROM SMS_DistributionPointInfo' -OperationTimeoutSec 120)
            foreach ($dp in $distributionPoints) {
                $candidate = [string](Get-ResourcePropertyValue $dp @('ServerName','Name','NALPath'))
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $candidateParts = @($candidate.TrimEnd('\') -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($candidateParts.Count -gt 0) { $candidate = [string]$candidateParts[-1] }
                    $candidate = $candidate.Trim('\').ToLowerInvariant()
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $distributionPointServers[$candidate] = $true }
                }
            }
        }
        catch {
            Write-Log $LogPath "SMS_DistributionPointInfo could not be queried; boundary-group site systems will be shown without role filtering: $($_.Exception.Message)" 'WARN'
        }

        $siteSystems = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace `
            -Query 'SELECT GroupID, ServerNALPath, SiteCode FROM SMS_BoundaryGroupSiteSystems' -OperationTimeoutSec 120)
        foreach ($system in $siteSystems) {
            $groupId = [int]$system.GroupID
            $server = ''
            $nal = [string]$system.ServerNALPath
            if (-not [string]::IsNullOrWhiteSpace($nal)) {
                $trimmedNal = $nal.TrimEnd('\')
                $parts = @($trimmedNal -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($parts.Count -gt 0) { $server = [string]$parts[-1] }
            }
            $isDistributionPoint = ($distributionPointServers.Count -eq 0) -or $distributionPointServers.ContainsKey($server.ToLowerInvariant())
            if (-not [string]::IsNullOrWhiteSpace($server) -and $isDistributionPoint) {
                if (-not $boundaryGroupDpMap.ContainsKey($groupId)) {
                    $boundaryGroupDpMap[$groupId] = New-Object System.Collections.Generic.List[string]
                }
                if (-not $boundaryGroupDpMap[$groupId].Contains($server)) {
                    $boundaryGroupDpMap[$groupId].Add($server)
                }
            }
        }
        Write-Log $LogPath "Loaded $($boundaryGroups.Count) boundary groups and $($siteSystems.Count) associated site-system records for Preferred Distribution Points." 'INFO'
    }
    catch {
        Write-Log $LogPath "Preferred Distribution Points lookup could not be initialized: $($_.Exception.Message)" 'WARN'
    }

    [pscustomobject]@{
        Summary                  = $summary
        Assets                   = $assets
        ResourceMap              = $resourceMap
        OsMap                    = $osMap
        BoundaryGroupNameToId    = $boundaryGroupNameToId
        BoundaryGroupDpMap       = $boundaryGroupDpMap
    }
}

function Test-IsSystemAccount {
    param([string]$UserID)
    if ([string]::IsNullOrWhiteSpace($UserID)) { return $false }
    $sam = ($UserID -split '\\')[-1].Trim('(', ')')
    return $sam -in @('SYSTEM', 'NETWORK SERVICE', 'LOCAL SERVICE', 'ANONYMOUS LOGON')
}

function Resolve-Upn {
    param(
        [string]$UserID,
        [hashtable]$Cache,
        [bool]$Enabled,
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($UserID)) {
        return [pscustomobject]@{ UPN = ''; Source = 'Not Resolved (no logged-on user)' }
    }

    if ($UserID -match '@') {
        return [pscustomobject]@{ UPN = $UserID; Source = 'SCCM' }
    }

    if ($Cache.ContainsKey($UserID)) { return $Cache[$UserID] }

    $result = [pscustomobject]@{ UPN = ''; Source = 'Not Resolved' }

    if ($Enabled) {
        try {
            if (-not (Get-Module ActiveDirectory)) {
                Import-Module ActiveDirectory -ErrorAction Stop
            }
            $sam = ($UserID -split '\\')[-1]
            $adUser = Get-ADUser -Filter "SamAccountName -eq '$($sam.Replace("'","''"))'" `
                -Properties UserPrincipalName, Mail -ErrorAction Stop | Select-Object -First 1
            if ($adUser -and $adUser.Mail) {
                $result = [pscustomobject]@{ UPN = [string]$adUser.Mail; Source = 'Active Directory (mail)' }
            }
            elseif ($adUser -and $adUser.UserPrincipalName) {
                $result = [pscustomobject]@{ UPN = [string]$adUser.UserPrincipalName; Source = 'Active Directory (login UPN, no mail set)' }
                if ($LogPath) { Write-Log $LogPath "UPN lookup: AD user '$sam' has no 'mail' attribute; falling back to login UserPrincipalName." 'WARN' }
            }
            else {
                $result = [pscustomobject]@{ UPN = ''; Source = 'Not Resolved (user not found in AD)' }
                if ($LogPath) { Write-Log $LogPath "UPN lookup: no AD user found for SamAccountName '$sam' (from UserID '$UserID')." 'WARN' }
            }
        }
        catch {
            $reason = if ($_.Exception.Message -match 'module|Import-Module') {
                'AD module unavailable'
            } else {
                'AD query error'
            }
            $result = [pscustomobject]@{ UPN = ''; Source = "Not Resolved ($reason)" }
            if ($LogPath) { Write-Log $LogPath "UPN lookup failed for '$UserID': $($_.Exception.Message)" 'WARN' }
        }
    }
    else {
        $result = [pscustomobject]@{ UPN = ''; Source = 'Not Resolved (AD resolution disabled)' }
    }

    $Cache[$UserID] = $result
    return $result
}

function Get-PendingRebootState {
    param(
        [string]$ComputerName,
        [bool]$Enabled
    )

    if (-not $Enabled) { return 'Not Queried' }
    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return 'Unable to Query' }

    try {
        $sessionOption = New-CimSessionOption -Protocol Dcom
        $session = New-CimSession -ComputerName $ComputerName -SessionOption $sessionOption `
            -OperationTimeoutSec 12 -ErrorAction Stop
        try {
            $result = Invoke-CimMethod -CimSession $session -Namespace 'root\ccm\ClientSDK' `
                -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' `
                -OperationTimeoutSec 12 -ErrorAction Stop
            if ($result.RebootPending -or $result.IsHardRebootPending) { return 'Yes' }
            return 'No'
        }
        finally {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
    }
    catch {
        return 'Unable to Query'
    }
}

# ---------------------------------------------------------------------------
# On-demand reboot-check server.
#
# The generated HTML reports are static files opened in a browser, and a
# browser cannot make CIM/DCOM calls to remote machines directly. To let the
# "Check" buttons in the report perform a real, live pending-reboot check
# without forcing the operator to enable the slow "query all devices" option
# up front, this app hosts a small HTTP server on 127.0.0.1 (loopback only,
# never reachable from the network) while it is running. The report's
# JavaScript calls this local server on click; the server performs the same
# CIM check as Get-PendingRebootState, one device at a time per request.
#
# A random per-session token is embedded in each generated report and
# required on every request, so only reports generated by this running app
# instance can use the endpoint.
# ---------------------------------------------------------------------------

function Start-RebootCheckServer {
    param(
        [int]$Port,
        [string]$Token,
        [string]$LogPath
    )

    # Use TcpListener instead of HttpListener. HttpListener depends on HTTP.sys
    # URL reservations and can fail for non-admin users with "Access denied",
    # making the HTML button show "Unavailable/No response - retry" before the
    # remote CIM query is even attempted. TcpListener binds only to loopback,
    # needs no URL ACL and preserves the same browser API used by the report.
    try {
        $listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            $Port
        )
        $listener.Start()
    }
    catch {
        Write-Log $LogPath "Reboot-check TCP server could not start on http://127.0.0.1:$Port/: $($_.Exception.Message). 'Check' buttons in reports will show as unavailable." 'WARN'
        return $null
    }

    $acceptScript = {
        param($Listener, $Token, $LogPath)

        function Send-HttpResponse {
            param(
                [System.Net.Sockets.NetworkStream]$Stream,
                [int]$StatusCode,
                [string]$StatusText,
                [string]$Body,
                [string]$ContentType = 'application/json; charset=utf-8'
            )

            if ($null -eq $Body) { $Body = '' }
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $headers = @(
                "HTTP/1.1 $StatusCode $StatusText",
                "Content-Type: $ContentType",
                "Content-Length: $($bodyBytes.Length)",
                'Access-Control-Allow-Origin: *',
                'Access-Control-Allow-Headers: Content-Type',
                'Access-Control-Allow-Methods: GET, OPTIONS',
                'Access-Control-Allow-Private-Network: true',
                'Connection: close',
                '',
                ''
            ) -join "`r`n"

            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
            $Stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($bodyBytes.Length -gt 0) {
                $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
            }
            $Stream.Flush()
        }

        function Get-QueryValues {
            param([string]$Target)
            $values = @{}
            $question = $Target.IndexOf('?')
            if ($question -lt 0 -or $question -ge ($Target.Length - 1)) { return $values }

            foreach ($pair in $Target.Substring($question + 1).Split('&')) {
                if ([string]::IsNullOrWhiteSpace($pair)) { continue }
                $parts = $pair.Split('=', 2)
                $key = [System.Uri]::UnescapeDataString(($parts[0] -replace '\+', ' '))
                $value = if ($parts.Count -gt 1) {
                    [System.Uri]::UnescapeDataString(($parts[1] -replace '\+', ' '))
                } else { '' }
                $values[$key] = $value
            }
            return $values
        }

        while ($true) {
            $client = $null
            $stream = $null
            try {
                $client = $Listener.AcceptTcpClient()
                $client.ReceiveTimeout = 5000
                $client.SendTimeout = 5000
                $stream = $client.GetStream()

                $reader = [System.IO.StreamReader]::new(
                    $stream,
                    [System.Text.Encoding]::ASCII,
                    $false,
                    4096,
                    $true
                )

                $requestLine = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($requestLine)) {
                    Send-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -Body '{"status":"Bad Request"}'
                    continue
                }

                # Consume request headers. Browser preflight headers do not need
                # special parsing; they only need a valid OPTIONS response.
                while ($true) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line -or $line.Length -eq 0) { break }
                }

                $requestParts = $requestLine.Split(' ')
                if ($requestParts.Count -lt 2) {
                    Send-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -Body '{"status":"Bad Request"}'
                    continue
                }

                $method = $requestParts[0].ToUpperInvariant()
                $target = $requestParts[1]

                if ($method -eq 'OPTIONS') {
                    Send-HttpResponse -Stream $stream -StatusCode 204 -StatusText 'No Content' -Body '' -ContentType 'text/plain; charset=utf-8'
                    continue
                }

                if ($method -ne 'GET') {
                    Send-HttpResponse -Stream $stream -StatusCode 405 -StatusText 'Method Not Allowed' -Body '{"status":"Method Not Allowed"}'
                    continue
                }

                $query = Get-QueryValues -Target $target
                $device = [string]$query['device']
                $tok = [string]$query['token']

                if ($tok -ne $Token) {
                    Send-HttpResponse -Stream $stream -StatusCode 401 -StatusText 'Unauthorized' -Body '{"status":"Unauthorized"}'
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($device)) {
                    Send-HttpResponse -Stream $stream -StatusCode 400 -StatusText 'Bad Request' -Body '{"status":"Bad Request"}'
                    continue
                }

                $checkScript = {
                    param([string]$ComputerName)
                    $session = $null
                    try {
                        $sessionOption = New-CimSessionOption -Protocol Dcom
                        $session = New-CimSession -ComputerName $ComputerName -SessionOption $sessionOption `
                            -OperationTimeoutSec 10 -ErrorAction Stop
                        $result = Invoke-CimMethod -CimSession $session -Namespace 'root\ccm\ClientSDK' `
                            -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' `
                            -OperationTimeoutSec 10 -ErrorAction Stop
                        if ($result.RebootPending -or $result.IsHardRebootPending) { return 'Yes' }
                        return 'No'
                    }
                    catch {
                        return 'Unable to Query'
                    }
                    finally {
                        if ($session) {
                            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
                        }
                    }
                }

                $nested = [powershell]::Create()
                try {
                    [void]$nested.AddScript($checkScript)
                    [void]$nested.AddArgument($device)
                    $asyncResult = $nested.BeginInvoke()

                    if ($asyncResult.AsyncWaitHandle.WaitOne(15000)) {
                        try {
                            $state = $nested.EndInvoke($asyncResult) | Select-Object -Last 1
                            if (-not $state) { $state = 'Unable to Query' }
                        }
                        catch {
                            $state = 'Unable to Query'
                        }
                    }
                    else {
                        $state = 'Unable to Query (timeout)'
                        try { $nested.Stop() } catch {}
                    }
                }
                finally {
                    try { $nested.Dispose() } catch {}
                }

                $payloadObject = [ordered]@{
                    status = [string]$state
                    device = $device
                }
                $payload = $payloadObject | ConvertTo-Json -Compress
                Send-HttpResponse -Stream $stream -StatusCode 200 -StatusText 'OK' -Body $payload
            }
            catch [System.Management.Automation.MethodInvocationException] {
                # AcceptTcpClient throws when Listener.Stop() is called during shutdown.
                if (-not $Listener.Server.IsBound) { break }
                if ($LogPath) {
                    try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN] Reboot-check TCP request error: $($_.Exception.Message)" -Encoding UTF8 } catch {}
                }
            }
            catch {
                if ($LogPath) {
                    try { Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [WARN] Reboot-check TCP request error: $($_.Exception.Message)" -Encoding UTF8 } catch {}
                }
                if ($stream) {
                    try { Send-HttpResponse -Stream $stream -StatusCode 500 -StatusText 'Internal Server Error' -Body '{"status":"Server Error"}' } catch {}
                }
            }
            finally {
                if ($stream) { try { $stream.Dispose() } catch {} }
                if ($client) { try { $client.Close() } catch {} }
            }
        }
    }

    $acceptPS = [powershell]::Create()
    [void]$acceptPS.AddScript($acceptScript)
    [void]$acceptPS.AddArgument($listener)
    [void]$acceptPS.AddArgument($Token)
    [void]$acceptPS.AddArgument($LogPath)
    $acceptHandle = $acceptPS.BeginInvoke()

    Write-Log $LogPath "Reboot-check TCP server listening on http://127.0.0.1:$Port/ (loopback only; no URL ACL required)." 'INFO'

    [pscustomobject]@{
        Listener     = $listener
        Pool         = $null
        AcceptPS     = $acceptPS
        AcceptHandle = $acceptHandle
    }
}

function Stop-RebootCheckServer {
    param($Server)
    if (-not $Server) { return }
    try { $Server.Listener.Stop() } catch {}
    try { $Server.Listener.Close() } catch {}
    try { $Server.AcceptPS.Stop() } catch {}
    try { $Server.AcceptPS.Dispose() } catch {}
    try { $Server.Pool.Close() } catch {}
    try { $Server.Pool.Dispose() } catch {}
}

function Get-DemoData {
    $statuses = @('Success','Success','Success','Success','Success','Success','Success',
                  'InProgress','InProgress','Error','Unknown','Unknown')
    $rows = for ($i = 0; $i -lt $statuses.Count; $i++) {
        $n = $i + 1
        $status = $statuses[$i]
        [pscustomobject]@{
            Device                  = ('DEMO-PC-{0:D3}' -f $n)
            ClientType              = 'Computer'
            Client                  = if ($n -eq 12) { 'No' } else { 'Yes' }
            CurrentLoggedOnUser     = "CONTOSO\user$n"
            UserUPN                 = "user$n@contoso.com"
            SiteCode                = 'PR1'
            ClientStatus            = if ($n -in 11,12) { 'Inactive' } else { 'Active' }
            ClientCheckResult       = if ($n -eq 12) { 'Failed' } else { 'Passed' }
            PolicyRequest           = (Get-Date).AddHours(-$n).ToString('yyyy-MM-dd HH:mm:ss')
            HeartbeatDDR            = (Get-Date).AddHours(-($n+1)).ToString('yyyy-MM-dd HH:mm:ss')
            HardwareScan            = (Get-Date).AddDays(-($n%7)).ToString('yyyy-MM-dd HH:mm:ss')
            SoftwareScan            = (Get-Date).AddDays(-($n%5)).ToString('yyyy-MM-dd HH:mm:ss')
            ManagementPoint         = 'MP01.CONTOSO.COM'
            StatusMessage           = (Get-Date).AddMinutes(-($n*9)).ToString('yyyy-MM-dd HH:mm:ss')
            PreferredDistributionPoints = if (($n % 2) -eq 0) { 'DP02.contoso.com' } else { 'DP01.contoso.com' }
            ADSite                  = if ($n % 2) { 'New-York' } else { 'Chicago' }
            Domain                  = 'CONTOSO'
            Uptime                  = ('{0}d {1}h {2}m' -f $n, ($n*2)%24, ($n*3)%60)
            OperatingSystem         = if ($n % 3) { 'Microsoft Windows 11 Enterprise' } else { 'Microsoft Windows 10 Enterprise' }
            OSBuildNumber           = if ($n % 3) { '10.0.26100' } else { '10.0.19045' }
            PendingRestart          = if ($n -in 8,9,10) { 'Yes' } elseif ($n -eq 12) { 'Unable to Query' } else { 'No' }
            DeploymentStatus        = $status
            ErrorCode               = if ($status -eq 'Error') { '0x80D02002' } else { '' }
            ErrorDetail             = if ($status -eq 'Error') { 'The download operation made no progress within the defined period.' } else { '' }
            RecommendedActions      = if ($status -eq 'Error') { '1. Confirm that the required update content is available on the assigned Distribution Point.  2. Validate Delivery Optimization, BITS, proxy, firewall, and network connectivity.  3. Review CAS.log, LocationServices.log, ContentTransferManager.log, and DataTransferService.log.' } else { '' }
            LastStatusTime          = (Get-Date).AddMinutes(-($n * 7)).ToString('yyyy-MM-dd HH:mm:ss')
            ResourceID              = 100000 + $n
        }
    }

    [pscustomobject]@{
        DeploymentName = 'DEMO - 2026-07 Monthly Security Updates'
        CollectionName = 'DEMO - Windows Workstations'
        CollectionID   = 'PR100000'
        AssignmentID   = 16777299
        DeploymentID   = 'DEMO-DEPLOYMENT-ID'
        Rows           = @($rows)
    }
}

function Get-WindowsVersionLabel {
    param(
        [string]$Caption,
        [string]$Build
    )
    if ([string]::IsNullOrWhiteSpace($Build)) { return '' }
    $major = ($Build -split '\.')[0]

    $isServer = $Caption -match '(?i)server'

    if ($isServer) {
        $serverMap = @{
            '14393' = '2016'
            '17763' = '2019'
            '20348' = '2022'
            '26100' = '2025'
        }
        if ($serverMap.ContainsKey($major)) { return $serverMap[$major] }
        return ''
    }

    $clientMap = @{
        '10240' = '1507';  '10586' = '1511';  '14393' = '1607'
        '15063' = '1703';  '16299' = '1709';  '17134' = '1803'
        '17763' = '1809';  '18362' = '1903';  '18363' = '1909'
        '19041' = '2004';  '19042' = '20H2';  '19043' = '21H1'
        '19044' = '21H2';  '19045' = '22H2'
        '22000' = '21H2';  '22621' = '22H2';  '22631' = '23H2'
        '26100' = '24H2';  '26200' = '25H2'
    }
    if ($clientMap.ContainsKey($major)) { return $clientMap[$major] }
    return ''
}

function Get-ResourcePropertyValue {
    param($Resource, [string[]]$Names)
    if (-not $Resource) { return $null }

    # Exact property access is dramatically faster than running Where-Object
    # repeatedly for every field of every device. Prefix matching is retained
    # only as a fallback for ConfigMgr properties with inventory suffixes.
    foreach ($name in $Names) {
        $property = $Resource.PSObject.Properties[$name]
        if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property.Value
        }
    }
    foreach ($name in $Names) {
        foreach ($property in $Resource.PSObject.Properties) {
            if ($property.Name -like "$name*" -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                return $property.Value
            }
        }
    }
    return $null
}

function Format-Uptime {
    param($LastBootUpTime)
    $boot = Convert-CimDate $LastBootUpTime
    if (-not $boot) { return '' }
    $span = (Get-Date) - $boot
    if ($span.TotalSeconds -lt 0) { return '' }
    return ('{0}d {1}h {2}m' -f [int]$span.TotalDays, $span.Hours, $span.Minutes)
}

function Get-ClientStatusLabel {
    param($Value, $ClientInstalled)
    if ($ClientInstalled -eq 0 -or $ClientInstalled -eq $false) { return 'No Client' }
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'Unknown' }
    if ($Value -eq 1 -or $Value -eq $true -or [string]$Value -match '^(1|Active)$') { return 'Active' }
    if ($Value -eq 0 -or $Value -eq $false -or [string]$Value -match '^(0|Inactive)$') { return 'Inactive' }
    return [string]$Value
}

function Get-ClientCheckResultLabel {
    param($PassValue, $ResultValue)
    if ($PassValue -eq 1 -or $PassValue -eq $true -or [string]$PassValue -match '^(1|Passed|Pass)$') { return 'Passed' }
    if ($PassValue -eq 2 -or [string]$PassValue -match '^(2|Failed|Fail|Unhealthy)$') { return 'Failed' }
    if ($null -ne $ResultValue -and -not [string]::IsNullOrWhiteSpace([string]$ResultValue)) { return [string]$ResultValue }
    return 'Unknown'
}


function Get-SccmPendingRebootInfo {
    param($Resource)

    # Configuration Manager exposes the console Pending Restart state as the
    # ClientState bitmask on SMS_CombinedDeviceResources. Multiple reasons can
    # be present at the same time.
    if ($null -eq $Resource) {
        return [pscustomobject]@{ Status = 'Unknown'; Reason = 'SCCM data unavailable'; ClientState = $null }
    }

    $raw = Get-ResourcePropertyValue $Resource @('ClientState')
    if ($null -eq $raw -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        return [pscustomobject]@{ Status = 'Unknown'; Reason = 'ClientState not reported'; ClientState = $null }
    }

    $state = 0
    if (-not [int]::TryParse([string]$raw, [ref]$state)) {
        return [pscustomobject]@{ Status = 'Unknown'; Reason = "Unrecognized ClientState: $raw"; ClientState = $raw }
    }

    if ($state -eq 0) {
        return [pscustomobject]@{ Status = 'No'; Reason = ''; ClientState = 0 }
    }

    $reasons = New-Object System.Collections.Generic.List[string]
    if (($state -band 1) -ne 0) { $reasons.Add('Configuration Manager') }
    if (($state -band 2) -ne 0) { $reasons.Add('File Rename') }
    if (($state -band 4) -ne 0) { $reasons.Add('Windows Update') }
    if (($state -band 8) -ne 0) { $reasons.Add('Add or Remove Feature') }

    $knownMask = 1 -bor 2 -bor 4 -bor 8
    $unknownBits = $state -band (-bnot $knownMask)
    if ($unknownBits -ne 0) { $reasons.Add("Other SCCM reason bits: $unknownBits") }
    if ($reasons.Count -eq 0) { $reasons.Add("ClientState $state") }

    return [pscustomobject]@{
        Status      = 'Yes'
        Reason      = ($reasons -join ' + ')
        ClientState = $state
    }
}

function Convert-AssetsToRows {
    param(
        [object[]]$Assets,
        [hashtable]$ResourceMap,
        [hashtable]$OsMap,
        [hashtable]$BoundaryGroupNameToId,
        [hashtable]$BoundaryGroupDpMap,
        [string]$SiteCode,
        [bool]$ResolveUpnEnabled,
        [bool]$PendingRebootEnabled,
        [string]$LogPath
    )

    $upnCache = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    $index = 0

    # Sequential remote CIM calls are the main cause of apparently frozen
    # progress in large deployments. For more than 500 devices, bulk Pending
    # Reboot checks are automatically deferred to the report's on-demand
    # Check button. All SCCM-hosted enrichment data is still generated.
    $effectivePendingRebootEnabled = $PendingRebootEnabled
    if ($PendingRebootEnabled -and $Assets.Count -gt 500) {
        $effectivePendingRebootEnabled = $false
        Write-Log $LogPath "Bulk live Pending Reboot query deferred for $($Assets.Count) devices to protect dashboard generation performance. SCCM ClientState remains populated; use Verify Live only when needed." 'WARN'
    }

    foreach ($asset in $Assets) {
        $index++
        $resource = $null
        if ($ResourceMap.ContainsKey([int]$asset.ResourceID)) {
            $resource = $ResourceMap[[int]$asset.ResourceID]
        }

        $userId = [string]$asset.UserID
        if (Test-IsSystemAccount $userId) { $userId = '' }
        if ([string]::IsNullOrWhiteSpace($userId) -and $resource) {
            foreach ($prop in @('CurrentLogonUser','UserName','LastLogonUserName','PrimaryUser')) {
                if ($resource.PSObject.Properties.Name -contains $prop -and $resource.$prop -and -not (Test-IsSystemAccount ([string]$resource.$prop))) {
                    $userId = [string]$resource.$prop
                    break
                }
            }
        }

        $upnResult = Resolve-Upn -UserID $userId -Cache $upnCache -Enabled $ResolveUpnEnabled -LogPath $LogPath
        $deviceName = [string]$asset.DeviceName

        # Use the SCCM database/provider value by default. This preserves the
        # optimized batch model and also exposes the reason shown by the console.
        $sccmReboot = Get-SccmPendingRebootInfo -Resource $resource
        $pending = $sccmReboot.Status
        $rebootReason = $sccmReboot.Reason
        $rebootClientState = $sccmReboot.ClientState

        # The checkbox remains available for small, explicitly requested live
        # validations. A live positive/negative result overrides only the status;
        # the SCCM reason remains visible as the last server-reported reason.
        if ($effectivePendingRebootEnabled) {
            $livePending = Get-PendingRebootState -ComputerName $deviceName -Enabled $true
            if ($livePending -in @('Yes','No')) { $pending = $livePending }
        }

        $clientType = ''
        $client = ''
        $clientStatus = 'Unknown'
        $clientCheckResult = 'Unknown'
        $policyRequest = ''
        $heartbeatDdr = ''
        $hardwareScan = ''
        $softwareScan = ''
        $managementPoint = ''
        $statusMessage = ''
        $preferredDistributionPoints = ''
        $adSite = ''
        $domain = ''
        $osName = ''
        $osBuild = ''
        $uptime = ''

        if ($resource) {
            $clientType = [string](Get-ResourcePropertyValue $resource @('ClientType'))
            $clientRaw = Get-ResourcePropertyValue $resource @('Client')
            $client = if ($clientRaw -eq 1 -or $clientRaw -eq $true) {'Yes'} elseif ($null -ne $clientRaw) {'No'} else {''}
            $clientStatus = Get-ClientStatusLabel (Get-ResourcePropertyValue $resource @('ClientActiveStatus','ClientActivity')) $clientRaw
            $clientCheckResult = Get-ClientCheckResultLabel (Get-ResourcePropertyValue $resource @('ClientCheckPass')) (Get-ResourcePropertyValue $resource @('ClientCheckResult'))
            $policyRequest = Format-DateValue (Get-ResourcePropertyValue $resource @('PolicyRequest','LastPolicyRequest'))
            $heartbeatDdr = Format-DateValue (Get-ResourcePropertyValue $resource @('LastDDR','HeartbeatDDR','LastHeartbeatDDR'))
            $hardwareScan = Format-DateValue (Get-ResourcePropertyValue $resource @('LastHW','LastHardwareScan'))
            $softwareScan = Format-DateValue (Get-ResourcePropertyValue $resource @('LastSW','LastSoftwareScan'))
            $managementPoint = [string](Get-ResourcePropertyValue $resource @('LastMPServerName','ManagementPoint','MPServerName'))
            $statusMessage = Format-DateValue (Get-ResourcePropertyValue $resource @('LastStatusMessage','StatusMessage'))
            $boundaryNamesRaw = Get-ResourcePropertyValue $resource @('BoundaryGroupNames','BoundaryGroups','BoundaryGroupName','BoundaryGroup')
            $boundaryNames = @()
            if ($null -ne $boundaryNamesRaw) {
                if ($boundaryNamesRaw -is [System.Array]) { $boundaryNames = @($boundaryNamesRaw) }
                else { $boundaryNames = @(([string]$boundaryNamesRaw) -split '[;,]') }
            }
            $dpNames = New-Object System.Collections.Generic.List[string]
            foreach ($boundaryNameValue in $boundaryNames) {
                $boundaryName = ([string]$boundaryNameValue).Trim()
                if ([string]::IsNullOrWhiteSpace($boundaryName)) { continue }
                if ($BoundaryGroupNameToId -and $BoundaryGroupNameToId.ContainsKey($boundaryName)) {
                    $groupId = [int]$BoundaryGroupNameToId[$boundaryName]
                    if ($BoundaryGroupDpMap -and $BoundaryGroupDpMap.ContainsKey($groupId)) {
                        foreach ($dpName in @($BoundaryGroupDpMap[$groupId])) {
                            if (-not [string]::IsNullOrWhiteSpace([string]$dpName) -and -not $dpNames.Contains([string]$dpName)) {
                                $dpNames.Add([string]$dpName)
                            }
                        }
                    }
                }
            }
            if ($dpNames.Count -gt 0) { $preferredDistributionPoints = ($dpNames | Sort-Object) -join '; ' }
            $adSite = [string](Get-ResourcePropertyValue $resource @('ADSiteName'))
            $domain = [string](Get-ResourcePropertyValue $resource @('Domain'))
            $osName = [string](Get-ResourcePropertyValue $resource @('OperatingSystemNameandVersion'))
            $osBuild = [string](Get-ResourcePropertyValue $resource @('OperatingSystemBuild','OSBuild','Build'))
        }

        # Hardware inventory (SMS_G_System_OPERATING_SYSTEM) is the authoritative source;
        # it overrides whatever (if anything) CombinedDeviceResources provided above.
        if ($OsMap -and $OsMap.ContainsKey([int]$asset.ResourceID)) {
            $osInfo = $OsMap[[int]$asset.ResourceID]
            if (-not [string]::IsNullOrWhiteSpace($osInfo.Caption)) { $osName = $osInfo.Caption }
            if (-not [string]::IsNullOrWhiteSpace($osInfo.BuildNumber)) { $osBuild = $osInfo.BuildNumber }
            $uptime = Format-Uptime $osInfo.LastBootUpTime
        }

        if ([string]::IsNullOrWhiteSpace($osName) -and [string]::IsNullOrWhiteSpace($osBuild) -and $LogPath) {
            Write-Log $LogPath "No OS name/build available for ResourceID $($asset.ResourceID) (device '$deviceName') from inventory or CombinedDeviceResources." 'WARN'
        }

        $errorCodeValue = 0
        if ([UInt64]$asset.StatusErrorCode -ne 0) {
            $errorCodeValue = [UInt64]$asset.StatusErrorCode
        }
        elseif ([UInt64]$asset.LastEnforcementErrorCode -ne 0) {
            $errorCodeValue = [UInt64]$asset.LastEnforcementErrorCode
        }

        $errorDetail = Get-ErrorDetail -Code $errorCodeValue `
            -LastEnforcementMessage ([string]$asset.LastEnforcementMessageDesc) `
            -StatusDescription ([string]$asset.StatusDescription)
        $recommendedActions = Get-ErrorRecommendations -Code $errorCodeValue

        $osVersion = Get-WindowsVersionLabel -Caption $osName -Build $osBuild

        $rows.Add([pscustomobject]@{
            Device                  = $deviceName
            ClientType              = $clientType
            Client                  = $client
            CurrentLoggedOnUser     = $userId
            UserUPN                 = $upnResult.UPN
            SiteCode                = $SiteCode
            ClientStatus            = $clientStatus
            ClientCheckResult       = $clientCheckResult
            PolicyRequest           = $policyRequest
            HeartbeatDDR            = $heartbeatDdr
            HardwareScan            = $hardwareScan
            SoftwareScan            = $softwareScan
            ManagementPoint         = $managementPoint
            StatusMessage           = $statusMessage
            PreferredDistributionPoints = $preferredDistributionPoints
            ADSite                  = $adSite
            Domain                  = $domain
            Uptime                  = $uptime
            OperatingSystem         = $osName
            OSVersion               = $osVersion
            OSBuildNumber           = $osBuild
            PendingRestart          = $pending
            RebootReason            = $rebootReason
            RebootClientState       = $rebootClientState
            DeploymentStatus        = Get-StatusName ([int]$asset.StatusType)
            ErrorCode               = Get-ErrorHex $errorCodeValue
            ErrorDetail             = $errorDetail
            RecommendedActions      = $recommendedActions
            LastStatusTime          = Format-DateValue $asset.StatusTime
            ResourceID              = [int]$asset.ResourceID
        })

        if (($index % 100) -eq 0) {
            Write-Log $LogPath "Processed $index of $($Assets.Count) device records."
        }
    }

    # PowerShell 5.1 can throw 'Argument types do not match' when a generic List[object]
    # is wrapped with @(...). Convert it explicitly to a normal object array.
    return $rows.ToArray()
}

function New-DetailPage {
    param(
        [string]$OutputPath,
        [string]$Status,
        [object[]]$Rows,
        [hashtable]$Meta,
        [string]$CheckApiBase,
        [string]$CheckToken
    )

    $titleStatus = if ($Status -eq 'InProgress') { 'In Progress' } else { $Status }
    $count = $Rows.Count
    $total = [int]$Meta.Total
    $percentage = if ($total -gt 0) { [math]::Round(($count / $total) * 100, 2) } else { 0 }

    $tableRows = foreach ($r in $Rows) {
        $statusClass = $r.DeploymentStatus.ToLower()
        $rebootValue = [string]$r.PendingRestart
        $deviceSafe = ConvertTo-HtmlSafe $r.Device
        $rebootReasonSafe = ConvertTo-HtmlSafe $r.RebootReason
        $rebootDisplay = ConvertTo-HtmlSafe $rebootValue
        $prCell = "<td class='pr-cell' data-reboot='$rebootDisplay'><span class='reboot-value'>$rebootDisplay</span> <button type='button' class='check-btn verify-live' data-device='$deviceSafe'>Verify Live</button></td>"
        $reasonCell = "<td class='reboot-reason' data-clientstate='$(ConvertTo-HtmlSafe $r.RebootClientState)'>$rebootReasonSafe</td>"
        "<tr data-status='$statusClass'>" +
        "<td>$(ConvertTo-HtmlSafe $r.Device)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ClientType)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.Client)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.CurrentLoggedOnUser)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.UserUPN)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.SiteCode)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ClientStatus)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ClientCheckResult)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.PolicyRequest)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.HeartbeatDDR)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.HardwareScan)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.SoftwareScan)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ManagementPoint)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.StatusMessage)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.PreferredDistributionPoints)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ADSite)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.Domain)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.Uptime)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.OperatingSystem)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.OSVersion)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.OSBuildNumber)</td>" +
        $prCell +
        $reasonCell +
        "<td><span class='badge $statusClass'>$(ConvertTo-HtmlSafe $titleStatus)</span></td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ErrorCode)</td>" +
        "<td class='error-detail'>$(ConvertTo-HtmlSafe $r.ErrorDetail)</td>" +
        "<td class='recommendations'>$(ConvertTo-HtmlSafe $r.RecommendedActions)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.LastStatusTime)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ResourceID)</td>" +
        "</tr>"
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$([System.Net.WebUtility]::HtmlEncode($titleStatus)) devices - SCCM Patch Dashboard</title>
<style>
:root{--bg:#f4f7fb;--panel:#fff;--text:#132238;--muted:#637083;--border:#dce3ec;--success:#1f9d55;--progress:#e7a900;--error:#d64545;--unknown:#7b8794;--accent:#2563eb}
*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--text)}
header{background:#10233f;color:white;padding:24px 30px}header h1{margin:0 0 8px;font-size:24px}.meta{display:flex;gap:18px;flex-wrap:wrap;font-size:14px;color:#d9e4f2}
main{padding:24px}.toolbar{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}.toolbar input,.toolbar select,.toolbar button{border:1px solid var(--border);border-radius:10px;padding:10px 12px;background:white;font:inherit}.toolbar input{min-width:300px;flex:1}.toolbar button{cursor:pointer;background:var(--accent);color:white;border-color:var(--accent)}
.summary{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:16px}.card{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:14px 18px;min-width:160px}.card strong{display:block;font-size:25px}.card span{color:var(--muted);font-size:13px}
.table-wrap{background:var(--panel);border:1px solid var(--border);border-radius:14px;overflow:auto;max-height:72vh}
table{border-collapse:separate;border-spacing:0;width:100%;min-width:4200px;font-size:13px}th,td{padding:10px 12px;border-bottom:1px solid var(--border);text-align:left;white-space:nowrap}th{position:sticky;top:0;background:#edf2f8;z-index:2;cursor:pointer}tr:hover td{background:#f8fbff}.error-detail{white-space:normal;min-width:360px;max-width:620px;line-height:1.35}.recommendations{white-space:normal;min-width:520px;max-width:760px;line-height:1.45}.reboot-reason{white-space:normal;min-width:210px;max-width:340px;line-height:1.35}.reboot-value{font-weight:600}
.badge{display:inline-block;border-radius:999px;padding:4px 9px;font-weight:600;color:white}.success{background:var(--success)}.inprogress{background:var(--progress);color:#332400}.error{background:var(--error)}.unknown{background:var(--unknown)}
.check-btn{display:inline-block;border:none;border-radius:999px;padding:5px 14px;font-weight:600;font-size:12px;color:white;background:var(--accent);cursor:pointer}.check-btn:hover{background:#1d4ed8}.check-btn:disabled{cursor:default;opacity:.7}
.check-btn.result-yes{background:var(--error)}.check-btn.result-no{background:var(--success)}.check-btn.result-error{background:var(--unknown)}
#checkAllBtn{background:#0f766e;border-color:#0f766e}#checkAllBtn:disabled{opacity:.6;cursor:default}
.small{font-size:12px;color:var(--muted)}@media(max-width:700px){main{padding:12px}header{padding:18px}.toolbar input{min-width:100%}}
</style>
</head>
<body>
<header>
<h1>$([System.Net.WebUtility]::HtmlEncode($titleStatus)) devices</h1>
<div class="meta">
<span><b>Deployment:</b> $(ConvertTo-HtmlSafe $Meta.DeploymentName)</span>
<span><b>Collection:</b> $(ConvertTo-HtmlSafe $Meta.CollectionName) ($(ConvertTo-HtmlSafe $Meta.CollectionID))</span>
<span><b>Assignment ID:</b> $(ConvertTo-HtmlSafe $Meta.AssignmentID)</span>
<span><b>Generated:</b> $(ConvertTo-HtmlSafe $Meta.Generated)</span>
</div>
</header>
<main>
<section class="summary">
<div class="card"><strong>$count</strong><span>Devices in this status</span></div>
<div class="card"><strong>$percentage%</strong><span>Of targeted devices</span></div>
<div class="card"><strong id="visibleCount">$count</strong><span>Visible after filters</span></div>
</section>
<div class="toolbar">
<input id="search" type="search" placeholder="Search hostname, UPN, user, error, reboot reason, client status, MP, DP, build...">
<select id="reboot"><option value="">All reboot states</option><option>Yes</option><option>No</option><option>Unknown</option><option>Unable to Query</option></select>
<select id="activity"><option value="">All client statuses</option><option>Active</option><option>Inactive</option><option>No Client</option><option>Unknown</option></select>
<button id="exportBtn" type="button">Export visible CSV</button>
<button id="checkAllBtn" type="button">Verify pending restart live (visible rows)</button>
</div>
<div class="table-wrap">
<table id="deviceTable">
<thead><tr>
<th>Device</th><th>Client Type</th><th>Client</th><th>Current Logged-on User</th><th>User UPN</th>
<th>Site Code</th><th>Client Status</th><th>Client Check Result</th><th>Policy Request</th><th>Heartbeat DDR</th><th>Hardware Scan</th><th>Software Scan</th><th>Management Point</th><th>Status Message</th><th>Preferred Distribution Points</th><th>AD Site</th><th>Domain</th><th>Uptime</th>
<th>Operating System</th><th>OS Version</th><th>OS Build Number</th><th>Pending Reboot</th><th>Reboot Reason</th><th>Deployment Status</th>
<th>Error Code</th><th>Error Detail</th><th>Recommended Actions</th><th>Last Status Time</th><th>Resource ID</th>
</tr></thead>
<tbody>
$($tableRows -join "`n")
</tbody>
</table>
</div>
<p class="small">Click any column heading to sort. The CSV export includes only rows currently visible.</p>
</main>
<script>
const CHECK_API_BASE="$(ConvertTo-JsString $CheckApiBase)";
const CHECK_TOKEN="$(ConvertTo-JsString $CheckToken)";
const table=document.getElementById('deviceTable');
const rows=[...table.tBodies[0].rows];
const search=document.getElementById('search');
const reboot=document.getElementById('reboot');
const activity=document.getElementById('activity');
const visibleCount=document.getElementById('visibleCount');

function applyFilters(){
 const q=search.value.toLowerCase().trim();
 let visible=0;
 rows.forEach(row=>{
   const text=row.innerText.toLowerCase();
   const prCell=row.querySelector('.pr-cell');
   const rebootValue=prCell?prCell.dataset.reboot:'';
   const activityCell=row.cells[6];
   const activityValue=activityCell?activityCell.innerText.trim():'';
   const show=(!q||text.includes(q))&&(!reboot.value||rebootValue===reboot.value)&&(!activity.value||activityValue===activity.value);
   row.style.display=show?'':'none';
   if(show)visible++;
 });
 visibleCount.textContent=visible;
}
[search,reboot,activity].forEach(el=>el.addEventListener('input',applyFilters));

[...table.tHead.rows[0].cells].forEach((th,index)=>{
 let asc=true;
 th.addEventListener('click',()=>{
   const visibleRows=rows.filter(r=>r.style.display!=='none');
   visibleRows.sort((a,b)=>a.cells[index].innerText.localeCompare(b.cells[index].innerText,undefined,{numeric:true})*(asc?1:-1));
   visibleRows.forEach(r=>table.tBodies[0].appendChild(r));
   asc=!asc;
 });
});

document.getElementById('exportBtn').addEventListener('click',()=>{
 const visibleRows=rows.filter(r=>r.style.display!=='none');
 const csv=[];
 const quote=v=>'"'+String(v).replaceAll('"','""')+'"';
 csv.push([...table.tHead.rows[0].cells].map(c=>quote(c.innerText)).join(','));
 visibleRows.forEach(r=>csv.push([...r.cells].map(c=>quote(c.innerText)).join(',')));
 const blob=new Blob(["\uFEFF"+csv.join('\r\n')],{type:'text/csv;charset=utf-8'});
 const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='Devices_$Status.csv';a.click();URL.revokeObjectURL(a.href);
});

// --- Live pending-reboot check, via the local app's loopback server ---
async function checkOneDevice(btn){
 const device=btn.dataset.device;
 const cell=btn.closest('.pr-cell');
 btn.disabled=true;
 btn.textContent='Checking…';
 const controller=new AbortController();
 const timeoutId=setTimeout(()=>controller.abort(),20000);
 try{
   const url=CHECK_API_BASE+'/check?device='+encodeURIComponent(device)+'&token='+encodeURIComponent(CHECK_TOKEN);
   const res=await fetch(url,{method:'GET',signal:controller.signal});
   if(!res.ok) throw new Error('HTTP '+res.status);
   const data=await res.json();
   const status=data.status||'Unable to Query';
   cell.dataset.reboot=status;
   if(status==='Yes'){cell.innerHTML='<button type="button" class="check-btn result-yes" disabled>Yes</button>';}
   else if(status==='No'){cell.innerHTML='<button type="button" class="check-btn result-no" disabled>No</button>';}
   else {cell.innerHTML='<button type="button" class="check-btn result-error" disabled>'+status+'</button>';}
 }catch(err){
   const label=(err&&err.name==='AbortError')?'No response — retry':'Unavailable — retry';
   cell.dataset.reboot='Unable to Query';
   cell.innerHTML='<button type="button" class="check-btn result-error" data-device="'+device+'" title="Check service unavailable or timed out. Is the SCCM Patch Dashboard app still open?">'+label+'</button>';
   cell.querySelector('button').addEventListener('click',(e)=>checkOneDevice(e.target));
 }finally{
   clearTimeout(timeoutId);
 }
 applyFilters();
}

table.tBodies[0].addEventListener('click',(e)=>{
 const btn=e.target.closest('.check-btn');
 if(btn && !btn.disabled) checkOneDevice(btn);
});

document.getElementById('checkAllBtn').addEventListener('click', async ()=>{
 const allBtn=document.getElementById('checkAllBtn');
 const visibleRows=rows.filter(r=>r.style.display!=='none');
 const targets=[];
 visibleRows.forEach(r=>{
   const btn=r.querySelector('.check-btn:not([disabled])');
   if(btn) targets.push(btn);
 });
 if(targets.length===0) return;
 allBtn.disabled=true;
 const originalLabel=allBtn.textContent;
 allBtn.textContent='Checking 0/'+targets.length+'…';
 let done=0;
 const concurrency=6;
 let nextIndex=0;
 async function worker(){
   while(nextIndex<targets.length){
     const btn=targets[nextIndex++];
     await checkOneDevice(btn);
     done++;
     allBtn.textContent='Checking '+done+'/'+targets.length+'…';
   }
 }
 await Promise.all(Array.from({length:Math.min(concurrency,targets.length)},worker));
 allBtn.textContent=originalLabel;
 allBtn.disabled=false;
});
</script>
</body>
</html>
"@

    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
}

function New-DashboardPage {
    param(
        [string]$OutputPath,
        [object[]]$Rows,
        [hashtable]$Meta,
        [object[]]$HistoryEntries,
        [object[]]$TopErrors,
        [string]$CycleFooterHtml = ''
    )

    $counts = @{
        Success    = @($Rows | Where-Object DeploymentStatus -eq 'Success').Count
        InProgress = @($Rows | Where-Object DeploymentStatus -eq 'InProgress').Count
        Error      = @($Rows | Where-Object DeploymentStatus -eq 'Error').Count
        Unknown    = @($Rows | Where-Object DeploymentStatus -eq 'Unknown').Count
    }
    $total = $Rows.Count

    function Pct([int]$n) {
        if ($total -eq 0) { return 0 }
        return [math]::Round(($n / $total) * 100, 2)
    }

    $successPct = Pct $counts.Success
    $progressPct = Pct $counts.InProgress
    $errorPct = Pct $counts.Error
    $unknownPct = Pct $counts.Unknown
    $historyJson = ConvertTo-Json @($HistoryEntries) -Compress
    $topErrorCards = if (@($TopErrors).Count -gt 0) {
        (@($TopErrors) | ForEach-Object { "<div class='error-rank' data-page='$($_.Page)'><strong>$(ConvertTo-HtmlSafe $_.ErrorCode)</strong><span>$($_.Count) devices</span><small>$(ConvertTo-HtmlSafe $_.ErrorDetail)</small></div>" }) -join "`n"
    } else { "<div class='note'>No error codes were reported in this execution.</div>" }

    $dashboard = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SCCM Monthly Patch Dashboard</title>
<style>
:root{--bg:#eef3f8;--panel:#fff;--text:#132238;--muted:#64748b;--border:#d8e1eb;--success:#1f9d55;--progress:#e7a900;--error:#d64545;--unknown:#7b8794;--accent:#2563eb}
*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:var(--bg);color:var(--text)}
header{background:linear-gradient(120deg,#0f2442,#173d6f);color:#fff;padding:28px 34px}h1{margin:0 0 10px;font-size:28px}.subtitle{font-size:15px;color:#dbe8f7;display:flex;gap:18px;flex-wrap:wrap}
main{padding:26px;max-width:1440px;margin:auto}.metrics{display:grid;grid-template-columns:repeat(5,minmax(150px,1fr));gap:14px;margin-bottom:20px}
.metric{background:var(--panel);border:1px solid var(--border);border-radius:16px;padding:16px;cursor:pointer;transition:.15s}.metric:hover{transform:translateY(-2px);box-shadow:0 8px 20px rgba(15,35,65,.08)}.metric .value{font-size:30px;font-weight:700}.metric .label{color:var(--muted);font-size:13px}.metric .pct{font-size:13px;margin-top:6px}
.layout{display:grid;grid-template-columns:minmax(360px,1fr) minmax(300px,.8fr);gap:18px}.panel{background:var(--panel);border:1px solid var(--border);border-radius:18px;padding:22px}
.chart-wrap{display:flex;justify-content:center;align-items:center;min-height:390px}svg{max-width:410px;width:100%;height:auto}.slice{cursor:pointer;transition:opacity .15s}.slice:hover{opacity:.82}.center-total{font-size:30px;font-weight:700;fill:var(--text)}.center-label{font-size:13px;fill:var(--muted)}
.legend{display:grid;gap:10px}.legend-item{display:grid;grid-template-columns:14px 1fr auto;gap:10px;align-items:center;padding:13px;border:1px solid var(--border);border-radius:12px;cursor:pointer}.legend-item:hover{background:#f8fbff}.dot{width:12px;height:12px;border-radius:50%}.legend-item strong{font-size:15px}.legend-item span{color:var(--muted);font-size:13px}.note{margin-top:16px;padding:13px;border-radius:12px;background:#edf5ff;color:#26496f;font-size:13px}
.successText{color:var(--success)}.progressText{color:#9b7200}.errorText{color:var(--error)}.unknownText{color:var(--unknown)}
.error-section{margin-top:18px}.error-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.error-rank{border:1px solid var(--border);border-radius:12px;padding:14px;cursor:pointer;display:grid;gap:5px}.error-rank:hover{background:#fff7f7}.error-rank strong{color:var(--error)}.error-rank span{font-weight:700}.error-rank small{color:var(--muted);line-height:1.35}.trend-wrap{margin-top:18px}.trend-chart{width:100%;height:260px;border:1px solid var(--border);border-radius:12px;background:#fbfdff}.weekly{font-size:28px;font-weight:700;color:var(--accent)}footer{text-align:center;color:var(--muted);font-size:12px;padding:22px}@media(max-width:900px){.metrics{grid-template-columns:repeat(2,1fr)}.layout{grid-template-columns:1fr}}@media(max-width:520px){main{padding:12px}header{padding:20px}.metrics{grid-template-columns:1fr}}
</style>
</head>
<body>
<header>
<h1>SCCM Monthly Patch Deployment Dashboard</h1>
<div class="subtitle">
<span><b>Deployment:</b> $(ConvertTo-HtmlSafe $Meta.DeploymentName)</span>
<span><b>Collection:</b> $(ConvertTo-HtmlSafe $Meta.CollectionName) ($(ConvertTo-HtmlSafe $Meta.CollectionID))</span>
<span><b>Assignment ID:</b> $(ConvertTo-HtmlSafe $Meta.AssignmentID)</span>
<span><b>Deployment ID:</b> $(ConvertTo-HtmlSafe $Meta.DeploymentID)</span>
<span><b>Generated:</b> $(ConvertTo-HtmlSafe $Meta.Generated)</span>
</div>
</header>
<main>
<section class="metrics">
<div class="metric" data-page=""><div class="value">$total</div><div class="label">Total targeted devices</div><div class="pct">All deployment states</div></div>
<div class="metric" data-page="Devices_Success.html"><div class="value successText">$($counts.Success)</div><div class="label">Success</div><div class="pct">$successPct%</div></div>
<div class="metric" data-page="Devices_InProgress.html"><div class="value progressText">$($counts.InProgress)</div><div class="label">In Progress</div><div class="pct">$progressPct%</div></div>
<div class="metric" data-page="Devices_Error.html"><div class="value errorText">$($counts.Error)</div><div class="label">Error</div><div class="pct">$errorPct%</div></div>
<div class="metric" data-page="Devices_Unknown.html"><div class="value unknownText">$($counts.Unknown)</div><div class="label">Unknown</div><div class="pct">$unknownPct%</div></div>
</section>
<section class="layout">
<div class="panel chart-wrap">
<svg id="donut" viewBox="0 0 420 420" role="img" aria-label="Deployment status donut chart">
<circle cx="210" cy="210" r="135" fill="none" stroke="#e7edf4" stroke-width="78"></circle>
<g id="slices" transform="rotate(-90 210 210)"></g>
<text x="210" y="205" text-anchor="middle" class="center-total">$total</text>
<text x="210" y="230" text-anchor="middle" class="center-label">targeted devices</text>
</svg>
</div>
<div class="panel">
<h2 style="margin-top:0">Deployment status</h2>
<div class="legend">
<div class="legend-item" data-page="Devices_Success.html"><div class="dot" style="background:var(--success)"></div><div><strong>Success</strong><br><span>Completed successfully</span></div><b>$($counts.Success) · $successPct%</b></div>
<div class="legend-item" data-page="Devices_InProgress.html"><div class="dot" style="background:var(--progress)"></div><div><strong>In Progress</strong><br><span>Evaluation or installation underway</span></div><b>$($counts.InProgress) · $progressPct%</b></div>
<div class="legend-item" data-page="Devices_Error.html"><div class="dot" style="background:var(--error)"></div><div><strong>Error</strong><br><span>One or more errors reported</span></div><b>$($counts.Error) · $errorPct%</b></div>
<div class="legend-item" data-page="Devices_Unknown.html"><div class="dot" style="background:var(--unknown)"></div><div><strong>Unknown</strong><br><span>No current compliance state</span></div><b>$($counts.Unknown) · $unknownPct%</b></div>
</div>
<div class="note">Click a donut segment, metric card or legend item to open that status device list in a new browser tab.</div>
</div>
</section>
<section class="panel error-section"><h2 style="margin-top:0">Top 3 error codes</h2><div class="error-grid">$topErrorCards</div><div class="note">Click an error code to open its affected device list in a new browser tab.</div></section>
<section class="panel trend-wrap"><h2 style="margin-top:0">Patch evolution history</h2><div><span class="weekly" id="weeklyProgress">0%</span> <span class="center-label">weekly success progression</span></div><svg id="trendChart" class="trend-chart" viewBox="0 0 1000 260" preserveAspectRatio="none"></svg><div class="note">History is stored locally and updated once per generated report for this deployment.</div></section>
$CycleFooterHtml
</main>
<footer>Generated by SCCM Monthly Patch Dashboard v2.5</footer>
<script>
const data=[
 {name:'Success',value:$($counts.Success),color:'#1f9d55',page:'Devices_Success.html'},
 {name:'In Progress',value:$($counts.InProgress),color:'#e7a900',page:'Devices_InProgress.html'},
 {name:'Error',value:$($counts.Error),color:'#d64545',page:'Devices_Error.html'},
 {name:'Unknown',value:$($counts.Unknown),color:'#7b8794',page:'Devices_Unknown.html'}
];
const total=data.reduce((s,d)=>s+d.value,0);
const group=document.getElementById('slices');
const radius=135,circ=2*Math.PI*radius;
let offset=0;
data.forEach(d=>{
 if(total===0||d.value===0)return;
 const rawLength=(d.value/total)*circ;
 const length=rawLength>0?Math.max(rawLength,4):0;
 const c=document.createElementNS('http://www.w3.org/2000/svg','circle');
 c.setAttribute('cx','210');c.setAttribute('cy','210');c.setAttribute('r',radius);
 c.setAttribute('fill','none');c.setAttribute('stroke',d.color);c.setAttribute('stroke-width','78');
 c.setAttribute('stroke-dasharray',length+' '+(circ-length));
 c.setAttribute('stroke-dashoffset',-offset);
 c.setAttribute('class','slice');c.setAttribute('tabindex','0');
 c.setAttribute('aria-label',d.name+': '+d.value);
 c.addEventListener('click',()=>window.open(d.page,'_blank'));
 c.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();window.open(d.page,'_blank')}});
 group.appendChild(c);offset+=length;
});
document.querySelectorAll('[data-page]').forEach(el=>{
 const page=el.dataset.page;if(!page)return;
 el.addEventListener('click',()=>window.open(page,'_blank'));
 el.setAttribute('tabindex','0');
 el.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();window.open(page,'_blank')}});
});
const history=$historyJson;
(function drawTrend(){
 const svg=document.getElementById('trendChart'); if(!svg||!history.length)return;
 const ns='http://www.w3.org/2000/svg',w=1000,h=260,p=35;
 const pts=history.map((x,i)=>({x:p+(history.length===1?0:i*(w-2*p)/(history.length-1)),y:h-p-(Number(x.SuccessPct)||0)*(h-2*p)/100,label:x.Date,pct:Number(x.SuccessPct)||0}));
 [0,25,50,75,100].forEach(v=>{const y=h-p-v*(h-2*p)/100;const line=document.createElementNS(ns,'line');line.setAttribute('x1',p);line.setAttribute('x2',w-p);line.setAttribute('y1',y);line.setAttribute('y2',y);line.setAttribute('stroke','#d8e1eb');svg.appendChild(line);});
 const poly=document.createElementNS(ns,'polyline');poly.setAttribute('fill','none');poly.setAttribute('stroke','#2563eb');poly.setAttribute('stroke-width','4');poly.setAttribute('points',pts.map(q=>q.x+','+q.y).join(' '));svg.appendChild(poly);
 pts.forEach(q=>{const c=document.createElementNS(ns,'circle');c.setAttribute('cx',q.x);c.setAttribute('cy',q.y);c.setAttribute('r','6');c.setAttribute('fill','#2563eb');const t=document.createElementNS(ns,'title');t.textContent=q.label+': '+q.pct+'%';c.appendChild(t);svg.appendChild(c);});
 const recent=history.slice(-7);const weekly=document.getElementById('weeklyProgress');weekly.textContent=recent.length>1?(Number(recent[recent.length-1].SuccessPct)-Number(recent[0].SuccessPct)).toFixed(2)+'%':'0.00%';
})();
</script>
</body>
</html>
"@

    Set-Content -LiteralPath $OutputPath -Value $dashboard -Encoding UTF8
}

function Export-ReportPackage {
    param(
        [object[]]$Rows,
        [string]$DeploymentName,
        [string]$CollectionName,
        [string]$CollectionID,
        [string]$AssignmentID,
        [string]$DeploymentID,
        [string]$BaseOutputFolder,
        [string]$LogPath,
        [string]$CheckApiBase,
        [string]$CheckToken,
        [string]$CycleFooterHtml = ''
    )

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $folderName = '{0}_{1}' -f (Get-SafeFileName $DeploymentName), $stamp
    $reportFolder = Join-Path $BaseOutputFolder $folderName
    New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null

    $meta = @{
        DeploymentName = $DeploymentName
        CollectionName = $CollectionName
        CollectionID   = $CollectionID
        AssignmentID   = $AssignmentID
        DeploymentID   = $DeploymentID
        Generated      = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Total          = $Rows.Count
    }

    $csvPath = Join-Path $reportFolder 'DeploymentDetails.csv'
    $Rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    foreach ($status in @('Success','InProgress','Error','Unknown')) {
        $statusRows = @($Rows | Where-Object DeploymentStatus -eq $status)
        $statusPath = Join-Path $reportFolder ("Devices_{0}.html" -f $status)
        New-DetailPage -OutputPath $statusPath -Status $status -Rows $statusRows -Meta $meta `
            -CheckApiBase $CheckApiBase -CheckToken $CheckToken
        $statusRows | Export-Csv -LiteralPath (Join-Path $reportFolder ("Devices_{0}.csv" -f $status)) `
            -NoTypeInformation -Encoding UTF8
    }

    $topErrors = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ErrorCode) } | Group-Object ErrorCode | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        $code = [string]$_.Name
        $safeCode = $code -replace '[^0-9A-Za-z_-]','_'
        $page = "Devices_Error_$safeCode.html"
        $errorRows = @($_.Group)
        New-DetailPage -OutputPath (Join-Path $reportFolder $page) -Status 'Error' -Rows $errorRows -Meta $meta -CheckApiBase $CheckApiBase -CheckToken $CheckToken
        $displayDetail = [string]($errorRows | Select-Object -First 1).ErrorDetail
        if ($displayDetail -match '^(Compliant|Compliance|Success|Succeeded|Installed|In Progress|InProgress|Not Required|Requirement Not Met)$') {
            try {
                $numericCode = [Convert]::ToUInt64(($code -replace '^0x',''),16)
                $displayDetail = Get-ErrorDetail -Code $numericCode -LastEnforcementMessage '' -StatusDescription ''
            }
            catch { $displayDetail = "No detailed description is currently mapped for $code." }
        }
        [pscustomobject]@{ ErrorCode=$code; Count=$_.Count; ErrorDetail=$displayDetail; Page=$page }
    })

    $historyRoot = Join-Path $BaseOutputFolder '_PatchDashboardHistory'
    New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
    $historyPath = Join-Path $historyRoot ((Get-SafeFileName ("{0}_{1}" -f $DeploymentName,$AssignmentID)) + '.json')
    $history = @()
    if (Test-Path -LiteralPath $historyPath) { try { $history = @(Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $history = @() } }
    $successCount = @($Rows | Where-Object DeploymentStatus -eq 'Success').Count
    $successPctHistory = if ($Rows.Count -gt 0) { [math]::Round(($successCount / $Rows.Count) * 100,2) } else { 0 }
    $today = Get-Date -Format 'yyyy-MM-dd'
    $history = @($history | Where-Object { [string]$_.Date -ne $today })
    $history += [pscustomobject]@{ Date=$today; Generated=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Success=$successCount; Total=$Rows.Count; SuccessPct=$successPctHistory }
    $history = @($history | Sort-Object Date | Select-Object -Last 90)
    $history | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $historyPath -Encoding UTF8
    Copy-Item -LiteralPath $historyPath -Destination (Join-Path $reportFolder 'PatchHistory.json') -Force

    $dashboardPath = Join-Path $reportFolder 'Dashboard.html'
    New-DashboardPage -OutputPath $dashboardPath -Rows $Rows -Meta $meta -HistoryEntries $history -TopErrors $topErrors -CycleFooterHtml $CycleFooterHtml

    Copy-Item -LiteralPath $LogPath -Destination (Join-Path $reportFolder 'Generation.log') -Force

    [pscustomobject]@{
        ReportFolder  = $reportFolder
        DashboardPath = $dashboardPath
    }
}


function Get-AvailableDeployments {
    param(
        [Parameter(Mandatory)][string]$ProviderServer,
        [Parameter(Mandatory)][string]$SiteCode
    )

    $namespace = "root\SMS\site_$SiteCode"

    $items = @(Get-CimInstance -ComputerName $ProviderServer `
        -Namespace $namespace `
        -ClassName SMS_DeploymentSummary `
        -OperationTimeoutSec 180 `
        -ErrorAction Stop |
        Where-Object {
            # FeatureType 5 represents Software Updates deployments.
            # Some environments may return FeatureType as a string-compatible value.
            ([int]$_.FeatureType -eq 5)
        } |
        ForEach-Object {
            $deploymentName = ''
            foreach ($propertyName in @('AssignmentName','DeploymentName','SoftwareName')) {
                if ($_.PSObject.Properties.Name -contains $propertyName -and $_.$propertyName) {
                    $deploymentName = [string]$_.$propertyName
                    break
                }
            }

            $deploymentId = ''
            foreach ($propertyName in @('DeploymentID','AssignmentID')) {
                if ($_.PSObject.Properties.Name -contains $propertyName -and $null -ne $_.$propertyName) {
                    $deploymentId = [string]$_.$propertyName
                    if (-not [string]::IsNullOrWhiteSpace($deploymentId)) { break }
                }
            }

            [pscustomobject]@{
                Name           = $deploymentName
                DeploymentID   = $deploymentId
                AssignmentID   = [int]$_.AssignmentID
                CollectionID   = [string]$_.CollectionID
                CollectionName = [string]$_.CollectionName
                CreationTime   = Format-DateValue $_.CreationTime
                Deadline       = Format-DateValue $_.EnforcementDeadline
                Success        = [int]$_.NumberSuccess
                InProgress     = [int]$_.NumberInProgress
                Error          = [int]$_.NumberErrors
                Unknown        = [int]$_.NumberUnknown
            }
        } |
        Sort-Object Name, CollectionName)

    return $items
}

function Get-DemoDeploymentList {
    @(
        [pscustomobject]@{
            Name='DEMO - 2026-07 Monthly Security Updates'
            DeploymentID='16790001'
            AssignmentID=16790001
            CollectionID='P0100010'
            CollectionName='All Windows Workstations'
            CreationTime=(Get-Date).AddDays(-8).ToString('yyyy-MM-dd HH:mm:ss')
            Deadline=(Get-Date).AddDays(-1).ToString('yyyy-MM-dd HH:mm:ss')
            Success=7; InProgress=2; Error=1; Unknown=2
        },
        [pscustomobject]@{
            Name='DEMO - 2026-07 Monthly Security Updates'
            DeploymentID='16790002'
            AssignmentID=16790002
            CollectionID='P0100011'
            CollectionName='Pilot Workstations'
            CreationTime=(Get-Date).AddDays(-10).ToString('yyyy-MM-dd HH:mm:ss')
            Deadline=(Get-Date).AddDays(-3).ToString('yyyy-MM-dd HH:mm:ss')
            Success=22; InProgress=1; Error=0; Unknown=1
        },
        [pscustomobject]@{
            Name='DEMO - Microsoft 365 Apps Monthly Update'
            DeploymentID='16790003'
            AssignmentID=16790003
            CollectionID='P0100012'
            CollectionName='Microsoft 365 Apps Devices'
            CreationTime=(Get-Date).AddDays(-6).ToString('yyyy-MM-dd HH:mm:ss')
            Deadline=(Get-Date).AddHours(-12).ToString('yyyy-MM-dd HH:mm:ss')
            Success=31; InProgress=5; Error=2; Unknown=4
        }
    )
}

# ---------------------------- WPF GUI ----------------------------

