function Invoke-CATDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$ProviderServer,
        [scriptblock]$ProgressCallback,
        [scriptblock]$LogCallback
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    function Send-Progress([int]$Percent,[string]$Task){ if($ProgressCallback){ & $ProgressCallback $Percent $Task } }
    function Send-Log([string]$Msg,[string]$Level='INFO'){ if($LogCallback){ & $LogCallback $Msg $Level }; Write-CATLog -Session $Session -Level $Level -Category 'Discovery' -Message $Msg | Out-Null }

    Send-Progress 5 'Validating input...'
    if ([string]::IsNullOrWhiteSpace($SiteCode)) { throw 'Site Code cannot be empty.' }
    if ([string]::IsNullOrWhiteSpace($ProviderServer)) { throw 'SMS Provider cannot be empty.' }
    $SiteCode = $SiteCode.Trim()
    $ProviderServer = $ProviderServer.Trim()
    $ns = "root\SMS\site_$SiteCode"

    Send-Log "Starting Discovery. SiteCode=$SiteCode Provider=$ProviderServer"
    Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Input' -Check 'Site Code' -Status 'Info' -Finding $SiteCode -Evidence $SiteCode -Source 'UserInput') | Out-Null
    Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Input' -Check 'SMS Provider' -Target $ProviderServer -Status 'Info' -Finding $ProviderServer -Evidence $ProviderServer -Source 'UserInput') | Out-Null

    Send-Progress 15 'Testing DNS...'
    try {
        $dns = [System.Net.Dns]::GetHostEntry($ProviderServer)
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Connectivity' -Check 'DNS Resolve' -Target $ProviderServer -Status 'Healthy' -Severity 'Info' -Finding 'DNS resolution succeeded.' -Evidence ($dns.HostName) -Source 'System.Net.Dns') | Out-Null
        Send-Log "DNS OK: $($dns.HostName)"
    } catch {
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Connectivity' -Check 'DNS Resolve' -Target $ProviderServer -Status 'Warning' -Severity 'Medium' -Finding 'DNS resolution failed.' -Recommendation 'Validate DNS record and name used for the SMS Provider.' -Evidence $_.Exception.Message -Source 'System.Net.Dns') | Out-Null
        Send-Log "DNS failed: $($_.Exception.Message)" 'WARN'
    }

    Send-Progress 25 'Testing Ping...'
    try {
        $ping = Test-Connection -ComputerName $ProviderServer -Count 1 -Quiet -ErrorAction Stop
        $status = if($ping){'Healthy'}else{'Warning'}
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Connectivity' -Check 'Ping' -Target $ProviderServer -Status $status -Severity $(if($ping){'Info'}else{'Medium'}) -Finding $(if($ping){'Ping succeeded.'}else{'Ping failed.'}) -Recommendation $(if($ping){'No action required.'}else{'ICMP may be blocked; continue validating WMI/WinRM.'}) -Evidence $ping -Source 'Test-Connection') | Out-Null
        Send-Log "Ping result: $ping"
    } catch { Send-Log "Ping exception: $($_.Exception.Message)" 'WARN' }

    Send-Progress 35 'Testing WinRM...'
    try {
        Test-WSMan -ComputerName $ProviderServer -ErrorAction Stop | Out-Null
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Connectivity' -Check 'WinRM' -Target $ProviderServer -Status 'Healthy' -Severity 'Info' -Finding 'WinRM is available.' -Evidence 'Test-WSMan succeeded.' -Source 'Test-WSMan') | Out-Null
        Send-Log 'WinRM OK'
    } catch {
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Connectivity' -Check 'WinRM' -Target $ProviderServer -Status 'Warning' -Severity 'Medium' -Finding 'WinRM test failed.' -Recommendation 'Remote server checks may require WinRM; enable/validate WinRM if remote role assessment is needed.' -Evidence $_.Exception.Message -Source 'Test-WSMan') | Out-Null
        Send-Log "WinRM failed: $($_.Exception.Message)" 'WARN'
    }

    Send-Progress 45 'Connecting to SMS Provider...'
    try {
        $site = Get-CimInstance -ComputerName $ProviderServer -Namespace $ns -ClassName SMS_Site -ErrorAction Stop | Select-Object -First 1
        $Session.Inventory.Site = $site
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'SMS Provider' -Check 'SMS Provider Connection' -Target $ProviderServer -Status 'Healthy' -Severity 'Info' -Finding 'Connected to SMS Provider.' -Recommendation 'No action required.' -Evidence $ns -Source 'SMS_Site') | Out-Null
        Send-Log 'SMS Provider connected.'
    } catch {
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'SMS Provider' -Check 'SMS Provider Connection' -Target $ProviderServer -Status 'Critical' -Severity 'High' -Finding 'Failed to connect to SMS Provider.' -Recommendation 'Validate Site Code, SMS Provider server, RBAC permissions and WMI namespace availability.' -Evidence $_.Exception.Message -Source 'SMS_Site') | Out-Null
        Send-Log "SMS Provider failed: $($_.Exception.Message)" 'ERROR'
        throw
    }

    Send-Progress 60 'Reading site information...'
    if($site){
        foreach($prop in 'SiteCode','SiteName','Version','BuildNumber','ServerName'){
            $val = try { $site.$prop } catch { $null }
            if($null -ne $val){ Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Site' -Check $prop -Target $ProviderServer -Status 'Info' -Finding ([string]$val) -Evidence ([string]$val) -Source 'SMS_Site') | Out-Null }
        }
    }

    Send-Progress 72 'Reading site systems and roles...'
    $roles = @(Get-CimInstance -ComputerName $ProviderServer -Namespace $ns -ClassName SMS_SystemResourceList -ErrorAction Stop)
    $Session.Inventory.Roles = $roles
    $servers = @($roles | Select-Object -ExpandProperty ServerName -Unique | Sort-Object)
    $Session.Inventory.Servers = $servers

    foreach($srv in $servers){
        $srvRoles = @($roles | Where-Object ServerName -eq $srv | Select-Object -ExpandProperty RoleName)
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Topology' -Check 'Site System Server' -Target $srv -Role ($srvRoles -join '; ') -Status 'Info' -Finding ("Server discovered with {0} role instance(s)." -f $srvRoles.Count) -Evidence ($srvRoles -join '; ') -Source 'SMS_SystemResourceList') | Out-Null
    }

    Send-Progress 85 'Calculating summary...'
    $counts = [ordered]@{}
    $counts.Servers = $servers.Count
    $counts.RoleInstances = $roles.Count
    $roleGroups = $roles | Group-Object RoleName
    foreach($g in $roleGroups){ $counts[$g.Name] = $g.Count }
    $Session.Inventory.Counts = $counts
    Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Summary' -Check 'Servers Found' -Status 'Healthy' -Severity 'Info' -Finding ([string]$servers.Count) -Evidence ([string]$servers.Count) -Source 'SMS_SystemResourceList') | Out-Null
    Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'Discovery' -Category 'Summary' -Check 'Role Instances Found' -Status 'Healthy' -Severity 'Info' -Finding ([string]$roles.Count) -Evidence ([string]$roles.Count) -Source 'SMS_SystemResourceList') | Out-Null

    Send-Progress 100 'Discovery completed.'
    $sw.Stop()
    Send-Log ("Discovery completed. Servers={0}; Roles={1}; Duration={2:n1}s" -f $servers.Count,$roles.Count,$sw.Elapsed.TotalSeconds)
    return $Session.Inventory
}
Export-ModuleMember -Function *
