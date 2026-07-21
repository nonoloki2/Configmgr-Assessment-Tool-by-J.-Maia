#requires -Version 5.1
<#
.SYNOPSIS
    SCCM Monthly Patch Dashboard - Prototype v2.2

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

    Prototype v2.2 includes Demo Mode so the interface and web report can be tested
    without connecting to SCCM.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
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
                foreach ($p in $row.PSObject.Properties) {
                    if ($p.Name -match '^Caption' -and $p.Value -and -not $caption) { $caption = [string]$p.Value }
                    elseif ($p.Name -match '^BuildNumber' -and $p.Value -and -not $build) { $build = [string]$p.Value }
                    elseif ($p.Name -match '^Version' -and $p.Value -and -not $version) { $version = [string]$p.Value }
                }
                $osMap[[int]$row.ResourceID] = [pscustomobject]@{
                    Caption     = $caption
                    BuildNumber = $build
                    Version     = $version
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

    [pscustomobject]@{
        Summary     = $summary
        Assets      = $assets
        ResourceMap = $resourceMap
        OsMap       = $osMap
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

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    try {
        $listener.Start()
    }
    catch {
        Write-Log $LogPath "Reboot-check server could not start on http://127.0.0.1:$Port/: $($_.Exception.Message). 'Check' buttons in reports will show as unavailable." 'WARN'
        return $null
    }

    # Note: each incoming request spawns its own short-lived nested runspace to
    # actually perform the CIM check (see worker script below), bounded by a
    # hard 15s deadline. This is necessary because ICMP (ping) reachability
    # does not guarantee WMI/DCOM ports (135 + dynamic RPC range) are open --
    # if they're blocked, New-CimSession's underlying TCP connect attempt can
    # hang far longer than the CIM operation timeout parameter accounts for.
    # The deadline guarantees the HTTP response (and therefore the "Check"
    # button in the report) always resolves, even against unreachable hosts.
    $pool = [runspacefactory]::CreateRunspacePool(1, 6)
    $pool.Open()

    $acceptScript = {
        param($Listener, $Pool, $Token, $LogPath)

        while ($Listener.IsListening) {
            try {
                $context = $Listener.GetContext()
            }
            catch {
                break
            }

            $worker = [powershell]::Create()
            $worker.RunspacePool = $Pool
            [void]$worker.AddScript({
                param($Context, $Token)
                $req = $Context.Request
                $resp = $Context.Response
                $resp.Headers.Add('Access-Control-Allow-Origin', '*')
                $resp.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
                $resp.Headers.Add('Access-Control-Allow-Methods', 'GET, OPTIONS')
                $resp.Headers.Add('Access-Control-Allow-Private-Network', 'true')
                try {
                    if ($req.HttpMethod -eq 'OPTIONS') {
                        $resp.StatusCode = 204
                        return
                    }

                    $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                    $device = $query['device']
                    $tok = $query['token']

                    if ($tok -ne $Token) {
                        $resp.StatusCode = 401
                        $payload = '{"status":"Unauthorized"}'
                    }
                    elseif ([string]::IsNullOrWhiteSpace($device)) {
                        $resp.StatusCode = 400
                        $payload = '{"status":"Bad Request"}'
                    }
                    else {
                        $checkScript = {
                            param([string]$ComputerName)
                            try {
                                $sessionOption = New-CimSessionOption -Protocol Dcom
                                $session = New-CimSession -ComputerName $ComputerName -SessionOption $sessionOption `
                                    -OperationTimeoutSec 10 -ErrorAction Stop
                                try {
                                    $result = Invoke-CimMethod -CimSession $session -Namespace 'root\ccm\ClientSDK' `
                                        -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' `
                                        -OperationTimeoutSec 10 -ErrorAction Stop
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

                        $nested = [powershell]::Create()
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
                        try { $nested.Dispose() } catch {}

                        $safeDevice = $device -replace '"', ''
                        $payload = '{{"status":"{0}","device":"{1}"}}' -f $state, $safeDevice
                    }

                    $buffer = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    $resp.ContentType = 'application/json'
                    $resp.ContentLength64 = $buffer.Length
                    $resp.OutputStream.Write($buffer, 0, $buffer.Length)
                }
                catch {
                    try { $resp.StatusCode = 500 } catch {}
                }
                finally {
                    try { $resp.OutputStream.Close() } catch {}
                }
            }) | Out-Null
            [void]$worker.AddArgument($context)
            [void]$worker.AddArgument($Token)
            $worker.BeginInvoke() | Out-Null
        }
    }

    $acceptPS = [powershell]::Create()
    [void]$acceptPS.AddScript($acceptScript)
    [void]$acceptPS.AddArgument($listener)
    [void]$acceptPS.AddArgument($pool)
    [void]$acceptPS.AddArgument($Token)
    [void]$acceptPS.AddArgument($LogPath)
    $acceptHandle = $acceptPS.BeginInvoke()

    Write-Log $LogPath "Reboot-check server listening on http://127.0.0.1:$Port/ (loopback only)." 'INFO'

    [pscustomobject]@{
        Listener     = $listener
        Pool         = $pool
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
            UPNSource               = 'Demo'
            SiteCode                = 'PR1'
            ClientActivity          = if ($n -in 11,12) { 'Inactive' } else { 'Active' }
            ADSite                  = if ($n % 2) { 'New-York' } else { 'Chicago' }
            DeviceStatus            = if ($n -in 10,12) { 'Offline' } else { 'Online' }
            Domain                  = 'CONTOSO'
            LastOnlineTime          = (Get-Date).AddHours(-$n).ToString('yyyy-MM-dd HH:mm:ss')
            OperatingSystem         = if ($n % 3) { 'Microsoft Windows 11 Enterprise' } else { 'Microsoft Windows 10 Enterprise' }
            OSBuildNumber           = if ($n % 3) { '10.0.26100' } else { '10.0.19045' }
            PendingRestart          = if ($n -in 8,9,10) { 'Yes' } elseif ($n -eq 12) { 'Unable to Query' } else { 'No' }
            DeploymentStatus        = $status
            StatusDescription       = switch ($status) {
                                        'Success' {'Compliant'}
                                        'InProgress' {'Installing updates'}
                                        'Error' {'Failed to install one or more updates'}
                                        default {'No status message received'}
                                      }
            ErrorCode               = if ($status -eq 'Error') { '0x87D00664' } else { '' }
            ErrorDescription        = if ($status -eq 'Error') { 'Update installation failed or timed out' } else { '' }
            LastStatusTime          = (Get-Date).AddMinutes(-($n * 7)).ToString('yyyy-MM-dd HH:mm:ss')
            LastEnforcementMessage  = switch ($status) {
                                        'Success' {'Successfully installed update(s)'}
                                        'InProgress' {'Installation in progress'}
                                        'Error' {'Enforcement failed'}
                                        default {'No enforcement state'}
                                      }
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

function Convert-AssetsToRows {
    param(
        [object[]]$Assets,
        [hashtable]$ResourceMap,
        [hashtable]$OsMap,
        [string]$SiteCode,
        [bool]$ResolveUpnEnabled,
        [bool]$PendingRebootEnabled,
        [string]$LogPath
    )

    $upnCache = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    $index = 0

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
        $pending = Get-PendingRebootState -ComputerName $deviceName -Enabled $PendingRebootEnabled

        $clientType = ''
        $client = ''
        $clientActivity = ''
        $adSite = ''
        $deviceStatus = ''
        $domain = ''
        $lastOnline = ''
        $osName = ''
        $osBuild = ''

        if ($resource) {
            foreach ($pair in @(
                @('ClientType','ClientType'),
                @('Client','Client'),
                @('ClientActivity','ClientActivity'),
                @('ADSiteName','ADSite'),
                @('DeviceOnlineStatus','DeviceStatus'),
                @('Domain','Domain'),
                @('LastOnlineTime','LastOnlineTime'),
                @('OperatingSystemNameandVersion','OperatingSystem'),
                @('OperatingSystemBuild','OSBuildNumber')
            )) {
                $sourceName = $pair[0]
                $targetName = $pair[1]
                if ($resource.PSObject.Properties.Name -contains $sourceName) {
                    $value = $resource.$sourceName
                    switch ($targetName) {
                        'ClientType' { $clientType = [string]$value }
                        'Client' { $client = if ($value -eq 1 -or $value -eq $true) {'Yes'} elseif ($null -ne $value) {'No'} else {''} }
                        'ClientActivity' { $clientActivity = [string]$value }
                        'ADSite' { $adSite = [string]$value }
                        'DeviceStatus' {
                            if ($value -eq 1 -or $value -eq $true) { $deviceStatus = 'Online' }
                            elseif ($null -ne $value) { $deviceStatus = 'Offline' }
                        }
                        'Domain' { $domain = [string]$value }
                        'LastOnlineTime' { $lastOnline = Format-DateValue $value }
                        'OperatingSystem' { $osName = [string]$value }
                        'OSBuildNumber' { $osBuild = [string]$value }
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($osBuild)) {
                foreach ($prop in @('OSBuild','Build','OperatingSystemBuild')) {
                    if ($resource.PSObject.Properties.Name -contains $prop -and $resource.$prop) {
                        $osBuild = [string]$resource.$prop
                        break
                    }
                }
            }
        }

        # Hardware inventory (SMS_G_System_OPERATING_SYSTEM) is the authoritative source;
        # it overrides whatever (if anything) CombinedDeviceResources provided above.
        if ($OsMap -and $OsMap.ContainsKey([int]$asset.ResourceID)) {
            $osInfo = $OsMap[[int]$asset.ResourceID]
            if (-not [string]::IsNullOrWhiteSpace($osInfo.Caption)) { $osName = $osInfo.Caption }
            if (-not [string]::IsNullOrWhiteSpace($osInfo.BuildNumber)) { $osBuild = $osInfo.BuildNumber }
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

        $errorDescription = ''
        if ($errorCodeValue -ne 0) {
            $errorDescription = [string]$asset.LastEnforcementMessageDesc
            if ([string]::IsNullOrWhiteSpace($errorDescription)) {
                $errorDescription = [string]$asset.StatusDescription
            }
        }

        $osVersion = Get-WindowsVersionLabel -Caption $osName -Build $osBuild

        $rows.Add([pscustomobject]@{
            Device                  = $deviceName
            ClientType              = $clientType
            Client                  = $client
            CurrentLoggedOnUser     = $userId
            UserUPN                 = $upnResult.UPN
            UPNSource               = $upnResult.Source
            SiteCode                = $SiteCode
            ClientActivity          = $clientActivity
            ADSite                  = $adSite
            DeviceStatus            = $deviceStatus
            Domain                  = $domain
            LastOnlineTime          = $lastOnline
            OperatingSystem         = $osName
            OSVersion               = $osVersion
            OSBuildNumber           = $osBuild
            PendingRestart          = $pending
            DeploymentStatus        = Get-StatusName ([int]$asset.StatusType)
            StatusDescription       = [string]$asset.StatusDescription
            ErrorCode               = Get-ErrorHex $errorCodeValue
            ErrorDescription        = $errorDescription
            LastStatusTime          = Format-DateValue $asset.StatusTime
            LastEnforcementMessage  = [string]$asset.LastEnforcementMessageDesc
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
        $prCell = if ($rebootValue -eq 'Not Queried') {
            "<td class='pr-cell' data-reboot='Not Queried'><button type='button' class='check-btn' data-device='$deviceSafe'>Check</button></td>"
        }
        else {
            "<td class='pr-cell' data-reboot='$(ConvertTo-HtmlSafe $rebootValue)'>$(ConvertTo-HtmlSafe $rebootValue)</td>"
        }
        "<tr data-status='$statusClass'>" +
        "<td>$(ConvertTo-HtmlSafe $r.Device)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ClientType)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.Client)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.CurrentLoggedOnUser)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.UserUPN)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.UPNSource)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.SiteCode)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ClientActivity)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ADSite)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.DeviceStatus)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.Domain)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.LastOnlineTime)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.OperatingSystem)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.OSVersion)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.OSBuildNumber)</td>" +
        $prCell +
        "<td><span class='badge $statusClass'>$(ConvertTo-HtmlSafe $titleStatus)</span></td>" +
        "<td>$(ConvertTo-HtmlSafe $r.StatusDescription)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ErrorCode)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.ErrorDescription)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.LastStatusTime)</td>" +
        "<td>$(ConvertTo-HtmlSafe $r.LastEnforcementMessage)</td>" +
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
table{border-collapse:separate;border-spacing:0;width:100%;min-width:2600px;font-size:13px}th,td{padding:10px 12px;border-bottom:1px solid var(--border);text-align:left;white-space:nowrap}th{position:sticky;top:0;background:#edf2f8;z-index:2;cursor:pointer}tr:hover td{background:#f8fbff}
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
<input id="search" type="search" placeholder="Search hostname, UPN, user, error, build...">
<select id="reboot"><option value="">All reboot states</option><option>Yes</option><option>No</option><option>Unable to Query</option><option>Not Queried</option></select>
<select id="activity"><option value="">All client activity</option><option>Active</option><option>Inactive</option></select>
<button id="exportBtn" type="button">Export visible CSV</button>
<button id="checkAllBtn" type="button">Check pending restart (visible rows)</button>
</div>
<div class="table-wrap">
<table id="deviceTable">
<thead><tr>
<th>Device</th><th>Client Type</th><th>Client</th><th>Current Logged-on User</th><th>User UPN</th><th>UPN Source</th>
<th>Site Code</th><th>Client Activity</th><th>AD Site</th><th>Device Status</th><th>Domain</th><th>Last Online Time</th>
<th>Operating System</th><th>OS Version</th><th>OS Build Number</th><th>Pending Restart</th><th>Deployment Status</th><th>Status Description</th>
<th>Error Code</th><th>Error Description</th><th>Last Status Time</th><th>Last Enforcement Message</th><th>Resource ID</th>
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
   const activityCell=row.cells[7];
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
        [hashtable]$Meta
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
footer{text-align:center;color:var(--muted);font-size:12px;padding:22px}@media(max-width:900px){.metrics{grid-template-columns:repeat(2,1fr)}.layout{grid-template-columns:1fr}}@media(max-width:520px){main{padding:12px}header{padding:20px}.metrics{grid-template-columns:1fr}}
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
</main>
<footer>Generated by SCCM Monthly Patch Dashboard Prototype v2.2</footer>
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
 const length=(d.value/total)*circ;
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
        [string]$CheckToken
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

    $dashboardPath = Join-Path $reportFolder 'Dashboard.html'
    New-DashboardPage -OutputPath $dashboardPath -Rows $Rows -Meta $meta

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

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SCCM Monthly Patch Dashboard - Prototype v2.2"
        Height="640" Width="1020" MinHeight="600" MinWidth="900"
        WindowStartupLocation="CenterScreen"
        WindowStyle="SingleBorderWindow"
        ResizeMode="CanMinimize"
        ShowInTaskbar="True"
        Background="#F1F5F9">
    <Grid Margin="20">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,14">
            <TextBlock Text="SCCM Monthly Patch Dashboard" FontSize="28" FontWeight="SemiBold" Foreground="#10233F"/>
            <TextBlock Text="Connect, search for a Software Updates deployment, select it and generate the web dashboard."
                       Margin="0,5,0,0" Foreground="#5B6778" FontSize="14"/>
        </StackPanel>

        <Border Grid.Row="1" Background="White" CornerRadius="14" BorderBrush="#D9E2EC"
                BorderThickness="1" Padding="18" Margin="0,0,0,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="145"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="100"/>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="155"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0" Text="SMS Provider" VerticalAlignment="Center" Margin="0,0,10,10"/>
                <TextBox x:Name="txtProvider" Grid.Row="0" Grid.Column="1" Height="33" Padding="8,5" Margin="0,0,12,10"/>
                <TextBlock Grid.Row="0" Grid.Column="2" Text="Site code" VerticalAlignment="Center" Margin="0,0,8,10"/>
                <TextBox x:Name="txtSiteCode" Grid.Row="0" Grid.Column="3" Height="33" Padding="8,5" Margin="0,0,12,10"/>
                <Button x:Name="btnConnect" Grid.Row="0" Grid.Column="4" Content="Connect and load" Height="33" Margin="0,0,0,10"/>

                <TextBlock Grid.Row="1" Grid.Column="0" Text="Search deployments" VerticalAlignment="Center" Margin="0,0,10,10"/>
                <TextBox x:Name="txtSearch" Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="3" Height="33" Padding="8,5"
                         Margin="0,0,12,10" IsEnabled="False"
                         ToolTip="Search by deployment name, collection name, collection ID or deployment ID"/>
                <Button x:Name="btnClearSearch" Grid.Row="1" Grid.Column="4" Content="Clear search" Height="33"
                        Margin="0,0,0,10" IsEnabled="False"/>

                <TextBlock Grid.Row="2" Grid.Column="0" Text="Options" VerticalAlignment="Top" Margin="0,3,10,0"/>
                <StackPanel Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="4" Orientation="Horizontal">
                    <CheckBox x:Name="chkDemo" Content="Demo mode" IsChecked="False" Margin="0,0,24,0"/>
                    <CheckBox x:Name="chkUpn" Content="Resolve UPN with Active Directory" IsChecked="True" Margin="0,0,24,0"/>
                    <CheckBox x:Name="chkReboot" Content="Query pending reboot live (slower)" IsChecked="False"/>
                </StackPanel>
            </Grid>
        </Border>

        <Border Grid.Row="2" Background="White" CornerRadius="14" BorderBrush="#D9E2EC"
                BorderThickness="1" Padding="16">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <DockPanel Grid.Row="0" Margin="0,0,0,10">
                    <TextBlock Text="Available Software Updates deployments" FontSize="17" FontWeight="SemiBold"
                               Foreground="#10233F" DockPanel.Dock="Left"/>
                    <TextBlock x:Name="txtCount" Text="0 deployments" Foreground="#64748B"
                               HorizontalAlignment="Right" DockPanel.Dock="Right"/>
                </DockPanel>

                <DataGrid x:Name="gridDeployments" Grid.Row="1" AutoGenerateColumns="False"
                          IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow"
                          CanUserAddRows="False" CanUserDeleteRows="False"
                          GridLinesVisibility="Horizontal" HeadersVisibility="Column"
                          BorderBrush="#D9E2EC" AlternatingRowBackground="#F8FAFC"
                          RowHeight="32"
                          ScrollViewer.HorizontalScrollBarVisibility="Visible"
                          ScrollViewer.VerticalScrollBarVisibility="Auto"
                          FrozenColumnCount="2">
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Deployment name" Binding="{Binding Name}" Width="520" MinWidth="320"/>
                        <DataGridTextColumn Header="Deployment ID" Binding="{Binding DeploymentID}" Width="260" MinWidth="160"/>
                        <DataGridTextColumn Header="Collection ID" Binding="{Binding CollectionID}" Width="120"/>
                        <DataGridTextColumn Header="Target collection" Binding="{Binding CollectionName}" Width="320" MinWidth="220"/>
                        <DataGridTextColumn Header="Created" Binding="{Binding CreationTime}" Width="155"/>
                        <DataGridTextColumn Header="Deadline" Binding="{Binding Deadline}" Width="155"/>
                        <DataGridTextColumn Header="Success" Binding="{Binding Success}" Width="80"/>
                        <DataGridTextColumn Header="In progress" Binding="{Binding InProgress}" Width="90"/>
                        <DataGridTextColumn Header="Error" Binding="{Binding Error}" Width="70"/>
                        <DataGridTextColumn Header="Unknown" Binding="{Binding Unknown}" Width="80"/>
                    </DataGrid.Columns>
                </DataGrid>

                <TextBlock Grid.Row="2" Margin="0,10,0,0" Foreground="#64748B" TextWrapping="Wrap"
                           Text="Select one row. The tool automatically uses its internal Assignment ID and collection information; the operator does not need to know internal SCCM identifiers."/>
            </Grid>
        </Border>

        <Grid Grid.Row="3" Margin="0,14,0,0">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0">
                <ProgressBar x:Name="progress" Height="16" Minimum="0" Maximum="100" Margin="0,0,0,7"/>
                <TextBlock x:Name="txtStatus" Text="Demo mode is enabled. Click Connect and load to preview the workflow."
                           Foreground="#526172" TextWrapping="Wrap"/>
            </StackPanel>

            <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Bottom">
                <Button x:Name="btnOutput" Content="Output folder..." Width="135" Height="40" Margin="0,0,10,0"/>
                <Button x:Name="btnGenerate" Content="Generate dashboard" Width="180" Height="40"
                        Background="#2563EB" Foreground="White" FontWeight="SemiBold"
                        Margin="0,0,10,0" IsEnabled="False"/>
                <Button x:Name="btnClose" Content="Close" Width="90" Height="40"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$controls = @{}
foreach ($name in @(
    'txtProvider','txtSiteCode','btnConnect','txtSearch','btnClearSearch',
    'chkDemo','chkUpn','chkReboot','gridDeployments','txtCount',
    'progress','txtStatus','btnOutput','btnGenerate','btnClose'
)) {
    $controls[$name] = $window.FindName($name)
}

$script:AllDeployments = @()
$script:OutputFolder = Join-Path ([Environment]::GetFolderPath('Desktop')) 'SCCM_Patch_Reports'

# App-level log (separate from the per-report generation log) used for
# startup diagnostics like the reboot-check server below.
$script:AppLogPath = Join-Path $env:TEMP 'SCCM_PatchDashboard_App.log'
try { Set-Content -LiteralPath $script:AppLogPath -Value '' -Encoding UTF8 -ErrorAction Stop } catch {}

# Local loopback server so the "Check" buttons in generated HTML reports can
# do an on-demand, live pending-reboot check without needing the slow
# "query all devices" checkbox during report generation. See
# Start-RebootCheckServer for details. Token is regenerated every app launch.
$script:RebootCheckPort = 8791
$script:RebootCheckToken = [Guid]::NewGuid().ToString('N')
$script:RebootCheckServer = Start-RebootCheckServer -Port $script:RebootCheckPort -Token $script:RebootCheckToken -LogPath $script:AppLogPath

$window.Add_Closing({
    Stop-RebootCheckServer -Server $script:RebootCheckServer
})

# A janela e redimensionada em relacao a resolucao reportada pela sessao,
# deixando margem de seguranca em cima/embaixo. Isso evita depender de
# WorkArea (que nao enxerga barras flutuantes desenhadas pelo cliente
# Citrix/CyberArk fora da sessao remota).
$window.Add_Loaded({
    $screenHeight = [System.Windows.SystemParameters]::PrimaryScreenHeight
    $screenWidth  = [System.Windows.SystemParameters]::PrimaryScreenWidth
    $safeHeight = [Math]::Min($window.Height, [Math]::Floor($screenHeight * 0.80))
    $safeWidth  = [Math]::Min($window.Width, [Math]::Floor($screenWidth * 0.90))
    if ($safeHeight -lt $window.MinHeight) { $safeHeight = $window.MinHeight }
    if ($safeWidth -lt $window.MinWidth) { $safeWidth = $window.MinWidth }
    $window.Height = $safeHeight
    $window.Width = $safeWidth
    $window.Left = [Math]::Max(0, ($screenWidth - $safeWidth) / 2)
    $window.Top = [Math]::Max(0, ($screenHeight - $safeHeight) * 0.60)
})

function Update-DeploymentGrid {
    $query = $controls.txtSearch.Text.Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($query)) {
        $filtered = @($script:AllDeployments)
    }
    else {
        $filtered = @($script:AllDeployments | Where-Object {
            ([string]$_.Name).ToLowerInvariant().Contains($query) -or
            ([string]$_.DeploymentID).ToLowerInvariant().Contains($query) -or
            ([string]$_.CollectionID).ToLowerInvariant().Contains($query) -or
            ([string]$_.CollectionName).ToLowerInvariant().Contains($query)
        })
    }

    $controls.gridDeployments.ItemsSource = $null
    $controls.gridDeployments.ItemsSource = $filtered
    $controls.txtCount.Text = "$($filtered.Count) deployment(s)"
    $controls.btnGenerate.IsEnabled = ($null -ne $controls.gridDeployments.SelectedItem)
}

function Set-DemoUiState {
    param([bool]$Enabled)

    $controls.txtProvider.IsEnabled = -not $Enabled
    $controls.txtSiteCode.IsEnabled = -not $Enabled

    if ($Enabled) {
        $controls.txtProvider.Text = ''
        $controls.txtSiteCode.Text = ''
        $controls.txtStatus.Text = 'Demo mode enabled. Click Connect and load to display sample deployments.'
    }
    else {
        $controls.txtStatus.Text = 'Enter the SMS Provider server and site code, then click Connect and load.'
    }

    $script:AllDeployments = @()
    $controls.gridDeployments.ItemsSource = $null
    $controls.txtSearch.IsEnabled = $false
    $controls.btnClearSearch.IsEnabled = $false
    $controls.btnGenerate.IsEnabled = $false
    $controls.txtCount.Text = '0 deployments'
}

$controls.chkDemo.Add_Checked({ Set-DemoUiState $true })
$controls.chkDemo.Add_Unchecked({ Set-DemoUiState $false })

$controls.btnConnect.Add_Click({
    $controls.btnConnect.IsEnabled = $false
    $controls.btnGenerate.IsEnabled = $false
    $controls.progress.Value = 10

    try {
        if ([bool]$controls.chkDemo.IsChecked) {
            $controls.txtStatus.Text = 'Loading sample deployments...'
            $window.Dispatcher.Invoke([action]{}, 'Background')
            Start-Sleep -Milliseconds 250
            $script:AllDeployments = @(Get-DemoDeploymentList)
            $controls.progress.Value = 100
            $controls.txtStatus.Text = 'Demo deployments loaded. Select one row and generate the dashboard.'
        }
        else {
            $provider = $controls.txtProvider.Text.Trim()
            $siteCode = $controls.txtSiteCode.Text.Trim().ToUpperInvariant()

            if ([string]::IsNullOrWhiteSpace($provider)) { throw 'Enter the SMS Provider server.' }
            if ([string]::IsNullOrWhiteSpace($siteCode)) { throw 'Enter the site code.' }

            $controls.txtStatus.Text = 'Validating the SMS Provider...'
            $window.Dispatcher.Invoke([action]{}, 'Background')

            $providerLocation = Get-CimInstance -ComputerName $provider `
                -Namespace 'root\SMS' `
                -ClassName SMS_ProviderLocation `
                -OperationTimeoutSec 30 `
                -ErrorAction Stop |
                Where-Object { $_.SiteCode -eq $siteCode } |
                Select-Object -First 1

            if (-not $providerLocation) {
                throw "The server is reachable, but no SMS Provider was found for site code $siteCode."
            }

            $controls.progress.Value = 35
            $controls.txtStatus.Text = 'Loading Software Updates deployments from SCCM...'
            $window.Dispatcher.Invoke([action]{}, 'Background')

            $script:AllDeployments = @(Get-AvailableDeployments `
                -ProviderServer $provider `
                -SiteCode $siteCode)

            if ($script:AllDeployments.Count -eq 0) {
                throw 'The connection succeeded, but no Software Updates deployments were returned.'
            }

            $controls.progress.Value = 100
            $controls.txtStatus.Text = "$($script:AllDeployments.Count) deployments loaded. Search and select the desired row."
        }

        $controls.txtSearch.IsEnabled = $true
        $controls.btnClearSearch.IsEnabled = $true
        $controls.txtSearch.Text = ''
        Update-DeploymentGrid
    }
    catch {
        $script:AllDeployments = @()
        Update-DeploymentGrid
        $controls.progress.Value = 0
        $controls.txtStatus.Text = "Connection/load failed: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show(
            $_.Exception.Message,
            'Connection/load failed',
            'OK',
            'Error'
        ) | Out-Null
    }
    finally {
        $controls.btnConnect.IsEnabled = $true
    }
})

$controls.txtSearch.Add_TextChanged({ Update-DeploymentGrid })

$controls.btnClearSearch.Add_Click({
    $controls.txtSearch.Text = ''
    $controls.txtSearch.Focus()
})

$controls.gridDeployments.Add_SelectionChanged({
    $selected = $controls.gridDeployments.SelectedItem
    $controls.btnGenerate.IsEnabled = ($null -ne $selected)

    if ($selected) {
        $controls.txtStatus.Text = "Selected: $($selected.Name) | Collection: $($selected.CollectionName) [$($selected.CollectionID)] | Deployment ID: $($selected.DeploymentID)"
    }
})

$controls.gridDeployments.Add_MouseDoubleClick({
    if ($controls.gridDeployments.SelectedItem) {
        $controls.btnGenerate.RaiseEvent(
            (New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))
        )
    }
})

$controls.btnOutput.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select the base folder for SCCM patch reports'
    $dialog.SelectedPath = $script:OutputFolder

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:OutputFolder = $dialog.SelectedPath
        $controls.txtStatus.Text = "Output folder: $script:OutputFolder"
    }
})

$controls.btnGenerate.Add_Click({
    $selected = $controls.gridDeployments.SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show(
            'Select one deployment before generating the report.',
            'No deployment selected',
            'OK',
            'Warning'
        ) | Out-Null
        return
    }

    $controls.btnGenerate.IsEnabled = $false
    $controls.btnConnect.IsEnabled = $false
    $controls.progress.Value = 5

    try {
        New-Item -ItemType Directory -Path $script:OutputFolder -Force | Out-Null

        $tempLog = Join-Path $env:TEMP (
            "SCCM_Patch_Dashboard_{0}.log" -f ([guid]::NewGuid().ToString('N'))
        )
        Set-Content -LiteralPath $tempLog -Value '' -Encoding UTF8

        if ([bool]$controls.chkDemo.IsChecked) {
            $controls.txtStatus.Text = 'Creating the demo device dataset...'
            $controls.progress.Value = 25
            $window.Dispatcher.Invoke([action]{}, 'Background')

            $demo = Get-DemoData
            $rows = $demo.Rows

            # Preserve the deployment selected in the grid as report context.
            $deploymentName = [string]$selected.Name
            $collectionName = [string]$selected.CollectionName
            $collectionID = [string]$selected.CollectionID
            $assignmentID = [int]$selected.AssignmentID
            $deploymentID = [string]$selected.DeploymentID

            Write-Log $tempLog "Demo report generated for selected deployment $deploymentID."
        }
        else {
            $provider = $controls.txtProvider.Text.Trim()
            $siteCode = $controls.txtSiteCode.Text.Trim().ToUpperInvariant()
            $assignmentID = [int]$selected.AssignmentID

            $controls.txtStatus.Text = "Reading device status for deployment $($selected.DeploymentID)..."
            $controls.progress.Value = 18
            $window.Dispatcher.Invoke([action]{}, 'Background')

            $providerData = Get-SmsProviderData `
                -ProviderServer $provider `
                -SiteCode $siteCode `
                -AssignmentID $assignmentID `
                -LogPath $tempLog

            $controls.txtStatus.Text = "Enriching $($providerData.Assets.Count) device records..."
            $controls.progress.Value = 42
            $window.Dispatcher.Invoke([action]{}, 'Background')

            $rows = Convert-AssetsToRows `
                -Assets $providerData.Assets `
                -ResourceMap $providerData.ResourceMap `
                -OsMap $providerData.OsMap `
                -SiteCode $siteCode `
                -ResolveUpnEnabled ([bool]$controls.chkUpn.IsChecked) `
                -PendingRebootEnabled ([bool]$controls.chkReboot.IsChecked) `
                -LogPath $tempLog

            $deploymentName = [string]$selected.Name
            $collectionName = [string]$selected.CollectionName
            $collectionID = [string]$selected.CollectionID
            $deploymentID = [string]$selected.DeploymentID
        }

        $controls.txtStatus.Text = 'Generating the dashboard, drill-down pages and CSV files...'
        $controls.progress.Value = 78
        $window.Dispatcher.Invoke([action]{}, 'Background')

        $checkApiBase = if ($script:RebootCheckServer) { "http://127.0.0.1:$($script:RebootCheckPort)" } else { '' }

        $result = Export-ReportPackage `
            -Rows $rows `
            -DeploymentName $deploymentName `
            -CollectionName $collectionName `
            -CollectionID $collectionID `
            -AssignmentID ([string]$assignmentID) `
            -DeploymentID $deploymentID `
            -BaseOutputFolder $script:OutputFolder `
            -LogPath $tempLog `
            -CheckApiBase $checkApiBase `
            -CheckToken $script:RebootCheckToken

        $controls.progress.Value = 100
        $controls.txtStatus.Text = "Completed. Dashboard: $($result.DashboardPath)"
        Start-Process $result.DashboardPath

        [System.Windows.MessageBox]::Show(
            "Dashboard generated successfully.`r`n`r`n$($result.ReportFolder)",
            'Report completed',
            'OK',
            'Information'
        ) | Out-Null
    }
    catch {
        $controls.progress.Value = 0

        $errorMessage = $_.Exception.Message
        $errorLine = $_.InvocationInfo.ScriptLineNumber
        $errorCommand = $_.InvocationInfo.Line
        $errorPosition = $_.InvocationInfo.PositionMessage
        $errorStack = $_.ScriptStackTrace

        $details = @(
            "Message: $errorMessage"
            "Line: $errorLine"
            "Command: $errorCommand"
            $errorPosition
            "Stack:"
            $errorStack
        ) -join "`r`n"

        if ($tempLog -and (Test-Path -LiteralPath $tempLog)) {
            Write-Log -Path $tempLog -Level 'ERROR' -Message ($details -replace "`r?`n", ' | ')
        }

        $controls.txtStatus.Text = "Report generation error at line $errorLine`: $errorMessage"

        [System.Windows.MessageBox]::Show(
            $details,
            'Dashboard generation error',
            'OK',
            'Error'
        ) | Out-Null
    }
    finally {
        $controls.btnConnect.IsEnabled = $true
        $controls.btnGenerate.IsEnabled = ($null -ne $controls.gridDeployments.SelectedItem)
    }
})

$controls.btnClose.Add_Click({ $window.Close() })

Set-DemoUiState $false
$null = $window.ShowDialog()
