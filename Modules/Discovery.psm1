Set-StrictMode -Version Latest

function Invoke-ConfigMgrDiscovery {
    param(
        [Parameter(Mandatory)] [string]$SiteCode,
        [Parameter(Mandatory)] [string]$ProviderServer,
        [Parameter(Mandatory)] [string]$AssessmentId,
        [scriptblock]$LogCallback,
        [scriptblock]$ProgressCallback
    )

    $results = New-Object System.Collections.Generic.List[object]
    $siteCode = $SiteCode.Trim().ToUpper()
    $provider = $ProviderServer.Trim()
    $namespace = "root\SMS\site_$siteCode"

    function Write-DiscoveryLog([string]$Message) {
        if ($LogCallback) { & $LogCallback $Message }
    }
    function Set-DiscoveryProgress([int]$Percent, [string]$Activity) {
        if ($ProgressCallback) { & $ProgressCallback $Percent $Activity }
    }

    Set-DiscoveryProgress 5 'Validating input'
    Write-DiscoveryLog "Starting Discovery. Assessment ID: $AssessmentId"

    if ([string]::IsNullOrWhiteSpace($siteCode)) {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Input' -Check 'Site Code' -Status Critical -Severity Critical -Finding 'Site Code is empty.' -Recommendation 'Enter a valid ConfigMgr Site Code.' -Source 'GUI'))
        return $results
    }
    if ([string]::IsNullOrWhiteSpace($provider)) {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Input' -Check 'SMS Provider' -Status Critical -Severity Critical -Finding 'SMS Provider is empty.' -Recommendation 'Enter the SMS Provider server name or FQDN.' -Source 'GUI'))
        return $results
    }

    $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Input' -Check 'Site Code' -Status Healthy -Finding "Site Code provided: $siteCode" -Evidence $siteCode -Source 'GUI'))
    $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Input' -Check 'SMS Provider' -Status Healthy -Finding "SMS Provider provided: $provider" -Evidence $provider -Source 'GUI'))

    Set-DiscoveryProgress 15 'Resolving DNS'
    Write-DiscoveryLog "Resolving DNS for $provider..."
    try {
        $dns = [System.Net.Dns]::GetHostEntry($provider)
        $ipList = ($dns.AddressList | ForEach-Object { $_.IPAddressToString }) -join '; '
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'DNS Resolve' -TargetServer $provider -Status Healthy -Finding 'DNS resolution succeeded.' -Evidence $ipList -Source 'System.Net.Dns'))
        Write-DiscoveryLog "DNS OK: $ipList"
    } catch {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'DNS Resolve' -TargetServer $provider -Status Warning -Severity Medium -Finding $_.Exception.Message -Recommendation 'Validate DNS record and name resolution from this workstation.' -Source 'System.Net.Dns'))
        Write-DiscoveryLog "DNS WARNING: $($_.Exception.Message)"
    }

    Set-DiscoveryProgress 25 'Testing ping'
    Write-DiscoveryLog "Testing ping to $provider..."
    try {
        $pingOk = Test-Connection -ComputerName $provider -Count 1 -Quiet -ErrorAction Stop
        if ($pingOk) {
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'Ping' -TargetServer $provider -Status Healthy -Finding 'Ping succeeded.' -Evidence 'ICMP reply received' -Source 'Test-Connection'))
            Write-DiscoveryLog 'Ping OK'
        } else {
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'Ping' -TargetServer $provider -Status Warning -Severity Medium -Finding 'Ping failed or ICMP blocked.' -Recommendation 'Validate network connectivity. ICMP may be blocked, so this is not always critical.' -Source 'Test-Connection'))
            Write-DiscoveryLog 'Ping WARNING: no ICMP reply'
        }
    } catch {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'Ping' -TargetServer $provider -Status Warning -Severity Medium -Finding $_.Exception.Message -Recommendation 'Validate network connectivity. ICMP may be blocked.' -Source 'Test-Connection'))
        Write-DiscoveryLog "Ping WARNING: $($_.Exception.Message)"
    }

    Set-DiscoveryProgress 35 'Testing WinRM'
    Write-DiscoveryLog "Testing WinRM on $provider..."
    try {
        Test-WSMan -ComputerName $provider -ErrorAction Stop | Out-Null
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'WinRM' -TargetServer $provider -Status Healthy -Finding 'WinRM is reachable.' -Evidence 'Test-WSMan succeeded' -Source 'Test-WSMan'))
        Write-DiscoveryLog 'WinRM OK'
    } catch {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Connectivity' -Check 'WinRM' -TargetServer $provider -Status Warning -Severity Medium -Finding $_.Exception.Message -Recommendation 'Enable/validate WinRM if remote server health checks will be used. Discovery through WMI/CIM may still work.' -Source 'Test-WSMan'))
        Write-DiscoveryLog "WinRM WARNING: $($_.Exception.Message)"
    }

    Set-DiscoveryProgress 50 'Connecting to SMS Provider namespace'
    Write-DiscoveryLog "Connecting to WMI namespace \\$provider\$namespace ..."
    $cim = $null
    try {
        $sessionOptions = New-CimSessionOption -Protocol Dcom
        $cim = New-CimSession -ComputerName $provider -SessionOption $sessionOptions -ErrorAction Stop
        Get-CimInstance -CimSession $cim -Namespace $namespace -ClassName SMS_ProviderLocation -ErrorAction SilentlyContinue | Out-Null
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'SMS Provider' -Check 'WMI Namespace Connection' -TargetServer $provider -Status Healthy -Finding "Connected to $namespace." -Evidence "\\$provider\$namespace" -Source 'CIM/WMI'))
        Write-DiscoveryLog 'SMS Provider namespace connection OK'
    } catch {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'SMS Provider' -Check 'WMI Namespace Connection' -TargetServer $provider -Status Critical -Severity Critical -Finding $_.Exception.Message -Recommendation "Validate Site Code, SMS Provider server, RBAC permissions and WMI access to namespace $namespace." -Evidence "\\$provider\$namespace" -Source 'CIM/WMI'))
        Write-DiscoveryLog "CRITICAL: Cannot connect to SMS Provider namespace. $($_.Exception.Message)"
        Set-DiscoveryProgress 100 'Discovery failed'
        if ($cim) { $cim | Remove-CimSession }
        return $results
    }

    Set-DiscoveryProgress 65 'Reading site information'
    Write-DiscoveryLog 'Reading site information...'
    try {
        $site = Get-CimInstance -CimSession $cim -Namespace $namespace -ClassName SMS_Site -ErrorAction Stop | Where-Object { $_.SiteCode -eq $siteCode } | Select-Object -First 1
        if ($site) {
            $siteName = if ($site.SiteName) { $site.SiteName } else { $site.SiteCode }
            $version = if ($site.Version) { $site.Version } else { 'Unknown' }
            $build = if ($site.BuildNumber) { $site.BuildNumber } else { 'Unknown' }
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site' -Check 'Site Name' -Status Info -Finding $siteName -Evidence $siteName -Source 'SMS_Site'))
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site' -Check 'ConfigMgr Version' -Status Info -Finding $version -Evidence $version -Source 'SMS_Site'))
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site' -Check 'Build Number' -Status Info -Finding $build -Evidence $build -Source 'SMS_Site'))
            Write-DiscoveryLog "Site: $siteName | Version: $version | Build: $build"
        } else {
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site' -Check 'Site Information' -Status Warning -Severity Medium -Finding 'SMS_Site did not return the requested site.' -Recommendation 'Validate the Site Code.' -Source 'SMS_Site'))
            Write-DiscoveryLog 'WARNING: Site information not found.'
        }
    } catch {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site' -Check 'Site Information' -Status UnableToCheck -Severity Medium -Finding $_.Exception.Message -Recommendation 'Validate permissions to read SMS_Site.' -Source 'SMS_Site'))
        Write-DiscoveryLog "WARNING: Cannot read SMS_Site. $($_.Exception.Message)"
    }

    Set-DiscoveryProgress 80 'Reading site systems and roles'
    Write-DiscoveryLog 'Reading site systems and roles...'
    try {
        $resources = Get-CimInstance -CimSession $cim -Namespace $namespace -ClassName SMS_SystemResourceList -ErrorAction Stop | Where-Object { $_.SiteCode -eq $siteCode }
        $serverCount = ($resources | Select-Object -ExpandProperty ServerName -Unique | Measure-Object).Count
        $roleCount = ($resources | Measure-Object).Count
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Discovery Summary' -Check 'Servers Found' -Status Info -Finding "$serverCount server(s) found." -Evidence $serverCount -Source 'SMS_SystemResourceList'))
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Discovery Summary' -Check 'Roles Found' -Status Info -Finding "$roleCount role instance(s) found." -Evidence $roleCount -Source 'SMS_SystemResourceList'))
        Write-DiscoveryLog "Servers found: $serverCount | Role instances found: $roleCount"

        foreach ($r in $resources | Sort-Object ServerName, RoleName) {
            $srv = [string]$r.ServerName
            $role = [string]$r.RoleName
            $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site System Role' -Check 'Role Discovered' -TargetServer $srv -Role $role -Status Info -Finding "$srv has role: $role" -Evidence $role -Source 'SMS_SystemResourceList'))
        }
    } catch {
        $results.Add((New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $siteCode -ProviderServer $provider -Category 'Site Systems' -Check 'Read Roles' -Status UnableToCheck -Severity High -Finding $_.Exception.Message -Recommendation 'Validate permissions to read SMS_SystemResourceList.' -Source 'SMS_SystemResourceList'))
        Write-DiscoveryLog "ERROR: Cannot read site systems/roles. $($_.Exception.Message)"
    }

    if ($cim) { $cim | Remove-CimSession }
    Set-DiscoveryProgress 100 'Discovery completed'
    Write-DiscoveryLog 'Discovery completed.'
    return $results
}

Export-ModuleMember -Function Invoke-ConfigMgrDiscovery
