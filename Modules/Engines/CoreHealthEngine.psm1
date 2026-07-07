function Invoke-CATCoreHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [scriptblock]$ProgressCallback,
        [scriptblock]$LogCallback
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    function Send-Progress([int]$Percent,[string]$Task){ if($ProgressCallback){ & $ProgressCallback $Percent $Task } }
    function Send-Log([string]$Msg,[string]$Level='INFO'){ if($LogCallback){ & $LogCallback $Msg $Level }; Write-CATLog -Session $Session -Level $Level -Category 'CoreHealth' -Message $Msg | Out-Null }
    function Add-HealthResult {
        param(
            [string]$Category,
            [string]$Check,
            [string]$Target,
            [string]$Role='',
            [string]$Status='Info',
            [string]$Severity='Info',
            [string]$Finding='',
            [string]$Recommendation='',
            [string]$Evidence='',
            [string]$Source='CoreHealth'
        )
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'CoreHealth' -Category $Category -Check $Check -Target $Target -Role $Role -Status $Status -Severity $Severity -Finding $Finding -Recommendation $Recommendation -Evidence $Evidence -Source $Source) | Out-Null
    }

    $servers = @($Session.Inventory.Servers | Sort-Object -Unique)
    if (-not $servers -or $servers.Count -eq 0) { throw 'Core Health requires a successful Discovery first. No site system servers were found in memory.' }

    if (-not $Session.Inventory.Contains('CoreHealth')) { $Session.Inventory['CoreHealth'] = @() }
    Send-Log "Starting Core Health. Servers=$($servers.Count)"
    Add-HealthResult -Category 'Summary' -Check 'Core Health Started' -Target '' -Status 'Info' -Finding "Core Health started for $($servers.Count) server(s)." -Evidence $servers.Count

    $index = 0
    foreach($server in $servers){
        $index++
        $roleText = (@($Session.Inventory.Roles | Where-Object ServerName -eq $server | Select-Object -ExpandProperty RoleName) -join '; ')
        $basePct = [int](($index - 1) / [double]$servers.Count * 100)
        Send-Progress $basePct "Core Health: $server ($index/$($servers.Count))"
        Send-Log "Checking $server"

        # DNS
        try {
            $dns = [System.Net.Dns]::GetHostEntry($server)
            Add-HealthResult -Category 'Connectivity' -Check 'DNS Resolve' -Target $server -Role $roleText -Status 'Healthy' -Severity 'Info' -Finding 'DNS resolution succeeded.' -Recommendation 'No action required.' -Evidence $dns.HostName -Source 'System.Net.Dns'
        } catch {
            Add-HealthResult -Category 'Connectivity' -Check 'DNS Resolve' -Target $server -Role $roleText -Status 'Warning' -Severity 'Medium' -Finding 'DNS resolution failed.' -Recommendation 'Validate DNS name, DNS suffix, and site system server record.' -Evidence $_.Exception.Message -Source 'System.Net.Dns'
        }

        # Ping
        $pingOk = $false
        try {
            $pingOk = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction Stop
            if($pingOk){
                Add-HealthResult -Category 'Connectivity' -Check 'Ping' -Target $server -Role $roleText -Status 'Healthy' -Severity 'Info' -Finding 'Ping succeeded.' -Recommendation 'No action required.' -Evidence 'True' -Source 'Test-Connection'
            } else {
                Add-HealthResult -Category 'Connectivity' -Check 'Ping' -Target $server -Role $roleText -Status 'Warning' -Severity 'Low' -Finding 'Ping failed or ICMP is blocked.' -Recommendation 'Validate network connectivity. ICMP may be blocked, so continue checking WinRM/CIM before treating as outage.' -Evidence 'False' -Source 'Test-Connection'
            }
        } catch {
            Add-HealthResult -Category 'Connectivity' -Check 'Ping' -Target $server -Role $roleText -Status 'Warning' -Severity 'Low' -Finding 'Ping test failed with exception.' -Recommendation 'Validate network connectivity or ICMP firewall rules.' -Evidence $_.Exception.Message -Source 'Test-Connection'
        }

        # WinRM
        $winrmOk = $false
        try {
            Test-WSMan -ComputerName $server -ErrorAction Stop | Out-Null
            $winrmOk = $true
            Add-HealthResult -Category 'Connectivity' -Check 'WinRM' -Target $server -Role $roleText -Status 'Healthy' -Severity 'Info' -Finding 'WinRM is available.' -Recommendation 'No action required.' -Evidence 'Test-WSMan succeeded.' -Source 'Test-WSMan'
        } catch {
            Add-HealthResult -Category 'Connectivity' -Check 'WinRM' -Target $server -Role $roleText -Status 'Warning' -Severity 'Medium' -Finding 'WinRM is not available or access was denied.' -Recommendation 'Validate WinRM service, firewall, TrustedHosts/Kerberos, and permissions. Some remote checks will be skipped.' -Evidence $_.Exception.Message -Source 'Test-WSMan'
        }

        if($winrmOk){
            # OS and uptime
            try {
                $os = Get-CimInstance -ComputerName $server -ClassName Win32_OperatingSystem -ErrorAction Stop
                $lastBoot = $os.LastBootUpTime
                $uptime = (Get-Date) - $lastBoot
                Add-HealthResult -Category 'Operating System' -Check 'OS Version' -Target $server -Role $roleText -Status 'Info' -Severity 'Info' -Finding $os.Caption -Recommendation 'No action required.' -Evidence ("Version={0}; Build={1}" -f $os.Version,$os.BuildNumber) -Source 'Win32_OperatingSystem'
                $upStatus = if($uptime.TotalDays -gt 90){'Warning'}else{'Healthy'}
                $upSeverity = if($uptime.TotalDays -gt 90){'Low'}else{'Info'}
                $upRecommendation = if($uptime.TotalDays -gt 90){'Review maintenance/reboot cadence. Long uptime can hide pending updates or service issues.'}else{'No action required.'}
                Add-HealthResult -Category 'Operating System' -Check 'Uptime' -Target $server -Role $roleText -Status $upStatus -Severity $upSeverity -Finding ("Uptime: {0:n1} days" -f $uptime.TotalDays) -Recommendation $upRecommendation -Evidence ("LastBoot={0}" -f $lastBoot) -Source 'Win32_OperatingSystem'
            } catch {
                Add-HealthResult -Category 'Operating System' -Check 'OS Inventory' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Finding 'Unable to query operating system via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_OperatingSystem'
            }

            # Disks
            try {
                $disks = @(Get-CimInstance -ComputerName $server -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
                foreach($disk in $disks){
                    if($disk.Size -gt 0){
                        $freePct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100,2)
                        $freeGB = [math]::Round($disk.FreeSpace / 1GB,2)
                        $sizeGB = [math]::Round($disk.Size / 1GB,2)
                        if($freePct -lt 10 -or $freeGB -lt 10){ $st='Critical'; $sev='High'; $rec='Free disk space is critically low. Validate logs, content library, WSUS/SUSDB, SQL, IIS logs and cleanup strategy.' }
                        elseif($freePct -lt 20 -or $freeGB -lt 20){ $st='Warning'; $sev='Medium'; $rec='Free disk space is below recommended threshold. Plan cleanup or expansion.' }
                        else { $st='Healthy'; $sev='Info'; $rec='No action required.' }
                        Add-HealthResult -Category 'Storage' -Check ("Disk Free Space {0}" -f $disk.DeviceID) -Target $server -Role $roleText -Status $st -Severity $sev -Finding ("{0} GB free of {1} GB ({2}%)" -f $freeGB,$sizeGB,$freePct) -Recommendation $rec -Evidence ("DeviceID={0}; FreeGB={1}; SizeGB={2}; FreePct={3}" -f $disk.DeviceID,$freeGB,$sizeGB,$freePct) -Source 'Win32_LogicalDisk'
                    }
                }
            } catch {
                Add-HealthResult -Category 'Storage' -Check 'Disk Inventory' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Finding 'Unable to query logical disks via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_LogicalDisk'
            }

            # Services
            $servicesToCheck = @('Winmgmt','LanmanServer','RemoteRegistry')
            if($roleText -match 'Management Point|Distribution Point|Software Update Point|Reporting|Application Catalog|Enrollment') { $servicesToCheck += 'W3SVC' }
            if($roleText -match 'Distribution Point') { $servicesToCheck += 'SMS_EXECUTIVE' }
            if($roleText -match 'Software Update Point') { $servicesToCheck += 'WsusService' }
            $servicesToCheck = $servicesToCheck | Sort-Object -Unique
            foreach($svcName in $servicesToCheck){
                try {
                    $svc = Get-CimInstance -ComputerName $server -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction Stop
                    if($null -eq $svc){
                        Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Status 'NotApplicable' -Severity 'Info' -Finding 'Service not present.' -Recommendation 'No action required if this service is not expected for this role.' -Evidence 'Not found' -Source 'Win32_Service'
                    } elseif($svc.State -eq 'Running'){
                        Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Status 'Healthy' -Severity 'Info' -Finding 'Service is running.' -Recommendation 'No action required.' -Evidence ("State={0}; StartMode={1}" -f $svc.State,$svc.StartMode) -Source 'Win32_Service'
                    } else {
                        $expected = if($svc.StartMode -eq 'Auto'){'Critical'}else{'Warning'}
                        $sev = if($svc.StartMode -eq 'Auto'){'High'}else{'Medium'}
                        Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Status $expected -Severity $sev -Finding ("Service is {0}." -f $svc.State) -Recommendation 'Validate the service state, event logs, and role-specific logs before remediation.' -Evidence ("State={0}; StartMode={1}" -f $svc.State,$svc.StartMode) -Source 'Win32_Service'
                    }
                } catch {
                    Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Finding 'Unable to query service via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_Service'
                }
            }
        } else {
            Add-HealthResult -Category 'Remote Checks' -Check 'CIM Dependent Checks' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Finding 'Skipped OS, disk and service checks because WinRM failed.' -Recommendation 'Fix WinRM/connectivity/permissions to enable full Core Health assessment.' -Evidence 'WinRM unavailable' -Source 'CoreHealthEngine'
        }
    }

    Send-Progress 100 'Core Health completed.'
    $sw.Stop()
    $coreResults = @($Session.Results | Where-Object Module -eq 'CoreHealth')
    $summary = [ordered]@{
        Servers = $servers.Count
        Healthy = @($coreResults | Where-Object Status -eq 'Healthy').Count
        Warning = @($coreResults | Where-Object Status -eq 'Warning').Count
        Critical = @($coreResults | Where-Object Status -eq 'Critical').Count
        UnableToCheck = @($coreResults | Where-Object Status -eq 'UnableToCheck').Count
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds,2)
    }
    $Session.Inventory.CoreHealth = $summary
    Add-HealthResult -Category 'Summary' -Check 'Core Health Completed' -Status 'Info' -Finding ("Core Health completed for $($servers.Count) server(s).") -Evidence ("Healthy={0}; Warning={1}; Critical={2}; UnableToCheck={3}" -f $summary.Healthy,$summary.Warning,$summary.Critical,$summary.UnableToCheck)
    Send-Log ("Core Health completed. Servers={0}; Healthy={1}; Warning={2}; Critical={3}; UnableToCheck={4}; Duration={5:n1}s" -f $summary.Servers,$summary.Healthy,$summary.Warning,$summary.Critical,$summary.UnableToCheck,$sw.Elapsed.TotalSeconds)
    return $summary
}
Export-ModuleMember -Function *
