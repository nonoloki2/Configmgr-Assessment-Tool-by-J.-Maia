function Invoke-CATCoreHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [scriptblock]$ProgressCallback,
        [scriptblock]$LogCallback
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $policy = $Session.Policy

    function Send-Progress([int]$Percent,[string]$Task){ if($ProgressCallback){ & $ProgressCallback $Percent $Task } }
    function Send-Log([string]$Msg,[string]$Level='INFO'){ if($LogCallback){ & $LogCallback $Msg $Level }; Write-CATLog -Session $Session -Level $Level -Category 'CoreHealth' -Message $Msg | Out-Null }
    function Add-HealthResult {
        param(
            [string]$Category,
            [string]$Check,
            [string]$Target,
            [string]$Role='',
            [string]$Value='',
            [string]$Status='Info',
            [string]$Severity='Info',
            [string]$Impact='',
            [string]$Finding='',
            [string]$Recommendation='',
            [string]$Evidence='',
            [string]$Source='CoreHealth',
            [string]$RuleId='',
            [double]$DurationSeconds=0
        )
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'CoreHealth' -Category $Category -Check $Check -Target $Target -Role $Role -Value $Value -Status $Status -Severity $Severity -Impact $Impact -Finding $Finding -Recommendation $Recommendation -Evidence $Evidence -Source $Source -RuleId $RuleId -DurationSeconds $DurationSeconds) | Out-Null
    }
    function Format-GB([double]$Bytes){ return [math]::Round($Bytes / 1GB, 2) }
    function Escape-CimFilterValue([string]$Value){ return $Value.Replace("'", "''") }
    function ConvertTo-CATDateTimeSafe {
        param([AllowNull()][object]$Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [datetime]) { return [datetime]$Value }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse($text, [ref]$dt)) { return $dt }
        return $null
    }
    function Get-CATPendingRebootState {
        param([string]$ComputerName)
        $scriptBlock = {
            $reasons = New-Object System.Collections.Generic.List[string]
            $paths = @(
                @{ Name='Component Based Servicing'; Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' },
                @{ Name='Windows Update'; Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' },
                @{ Name='Pending File Rename Operations'; Path='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'; Value='PendingFileRenameOperations' },
                @{ Name='Computer Rename Pending'; Path='HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'; ComparePath='HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' },
                @{ Name='Server Manager Reboot Required'; Path='HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts' }
            )
            foreach($item in $paths){
                try {
                    if($item.ComparePath){
                        $active = (Get-ItemProperty -Path $item.Path -ErrorAction Stop).ComputerName
                        $pending = (Get-ItemProperty -Path $item.ComparePath -ErrorAction Stop).ComputerName
                        if($active -ne $pending){ $reasons.Add($item.Name) | Out-Null }
                    } elseif($item.Value){
                        $prop = Get-ItemProperty -Path $item.Path -Name $item.Value -ErrorAction SilentlyContinue
                        if($prop -and $prop.PSObject.Properties[$item.Value] -and $prop.PSObject.Properties[$item.Value].Value){ $reasons.Add($item.Name) | Out-Null }
                    } else {
                        if(Test-Path -LiteralPath $item.Path){ $reasons.Add($item.Name) | Out-Null }
                    }
                } catch { }
            }
            [pscustomobject]@{ Pending = ($reasons.Count -gt 0); Reasons = @($reasons) }
        }
        Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
    }

    $servers = @($Session.Inventory.Servers | Sort-Object -Unique)
    if (-not $servers -or $servers.Count -eq 0) { throw 'Core Health requires a successful Discovery first. No site system servers were found in memory.' }

    Send-Log "Starting Core Health Professional. Servers=$($servers.Count)"
    Add-HealthResult -Category 'Summary' -Check 'Core Health Started' -Status 'Info' -Finding "Core Health Professional started for $($servers.Count) server(s)." -Value $servers.Count -Evidence $servers.Count

    $index = 0
    foreach($server in $servers){
        $serverSw = [System.Diagnostics.Stopwatch]::StartNew()
        $index++
        $roleText = (@($Session.Inventory.Roles | Where-Object ServerName -eq $server | Select-Object -ExpandProperty RoleName) -join '; ')
        $basePct = [int](($index - 1) / [double]$servers.Count * 100)
        Send-Progress $basePct "Core Health: $server ($index/$($servers.Count))"
        Send-Log "Checking $server"

        # DNS forward and reverse
        try {
            $dns = [System.Net.Dns]::GetHostEntry($server)
            $ips = @($dns.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
            $primaryIp = if($ips.Count -gt 0){ $ips[0] } else { '' }
            $reverseHost = ''
            if($primaryIp){
                try { $reverseHost = ([System.Net.Dns]::GetHostEntry($primaryIp)).HostName } catch { $reverseHost = 'Reverse lookup failed: ' + $_.Exception.Message }
            }
            Add-HealthResult -Category 'Connectivity' -Check 'DNS Resolve' -Target $server -Role $roleText -Value ($ips -join '; ') -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'DNS resolution succeeded.' -Recommendation 'No action required.' -Evidence ("Hostname={0}; IPs={1}; Reverse={2}" -f $dns.HostName,($ips -join '|'),$reverseHost) -Source 'System.Net.Dns'
        } catch {
            Add-HealthResult -Category 'Connectivity' -Check 'DNS Resolve' -Target $server -Role $roleText -Value '' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'DNS resolution failed.' -Recommendation 'Validate DNS name, DNS suffix, forward and reverse records for the site system server.' -Evidence $_.Exception.Message -Source 'System.Net.Dns'
        }

        # Ping latency and packet loss
        try {
            $pingCount = [int]$policy.Ping.PingCount
            if($pingCount -lt 1){ $pingCount = 4 }
            $pingReplies = @(Test-Connection -ComputerName $server -Count $pingCount -ErrorAction SilentlyContinue)
            $success = @($pingReplies | Where-Object { $_ -and $_.ResponseTime -ne $null })
            $lossPct = [math]::Round((($pingCount - $success.Count) / [double]$pingCount) * 100, 2)
            if($success.Count -gt 0){
                $avg = [math]::Round((($success | Measure-Object -Property ResponseTime -Average).Average), 2)
                $min = [math]::Round((($success | Measure-Object -Property ResponseTime -Minimum).Minimum), 2)
                $max = [math]::Round((($success | Measure-Object -Property ResponseTime -Maximum).Maximum), 2)
            } else { $avg = 9999; $min = 0; $max = 0 }
            $rule = Get-CATRuleDecision -RuleId 'CORE-PING-001' -Data @{ AverageMs=$avg; LossPct=$lossPct } -Policy $policy
            Add-HealthResult -Category 'Connectivity' -Check 'Ping' -Target $server -Role $roleText -Value ("Avg={0}ms; Loss={1}%" -f $avg,$lossPct) -Status $rule.Status -Severity $rule.Severity -Impact $rule.Impact -Finding ("Ping average {0} ms; min {1} ms; max {2} ms; packet loss {3}%." -f $avg,$min,$max,$lossPct) -Recommendation $rule.Recommendation -Evidence ("Count={0}; Success={1}; AverageMs={2}; MinMs={3}; MaxMs={4}; LossPct={5}" -f $pingCount,$success.Count,$avg,$min,$max,$lossPct) -Source 'Test-Connection' -RuleId 'CORE-PING-001'
        } catch {
            Add-HealthResult -Category 'Connectivity' -Check 'Ping' -Target $server -Role $roleText -Status 'Warning' -Severity 'Low' -Impact 'Medium' -Finding 'Ping test failed with exception.' -Recommendation 'Validate network connectivity or ICMP firewall rules.' -Evidence $_.Exception.Message -Source 'Test-Connection' -RuleId 'CORE-PING-001'
        }

        # WinRM response time
        $winrmOk = $false
        try {
            $wSw = [System.Diagnostics.Stopwatch]::StartNew()
            Test-WSMan -ComputerName $server -ErrorAction Stop | Out-Null
            $wSw.Stop()
            $winrmOk = $true
            Add-HealthResult -Category 'Connectivity' -Check 'WinRM' -Target $server -Role $roleText -Value ("{0} ms" -f $wSw.ElapsedMilliseconds) -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding ("WinRM is available. Response time: {0} ms." -f $wSw.ElapsedMilliseconds) -Recommendation 'No action required.' -Evidence ("ElapsedMs={0}" -f $wSw.ElapsedMilliseconds) -Source 'Test-WSMan'
        } catch {
            Add-HealthResult -Category 'Connectivity' -Check 'WinRM' -Target $server -Role $roleText -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'WinRM is not available or access was denied.' -Recommendation 'Validate WinRM service, firewall, Kerberos/SPN, TrustedHosts if applicable, and permissions. CIM-dependent checks will be skipped.' -Evidence $_.Exception.Message -Source 'Test-WSMan'
        }

        if($winrmOk){
            # OS, last boot and uptime
            try {
                $os = Get-CimInstance -ComputerName $server -ClassName Win32_OperatingSystem -ErrorAction Stop
                $lastBoot = $os.LastBootUpTime
                $uptime = (Get-Date) - $lastBoot
                $uptimeDays = [math]::Round($uptime.TotalDays, 1)
                Add-HealthResult -Category 'Operating System' -Check 'OS Version' -Target $server -Role $roleText -Value ("{0} {1}" -f $os.Caption,$os.BuildNumber) -Status 'Info' -Severity 'Info' -Impact 'Low' -Finding $os.Caption -Recommendation 'No action required.' -Evidence ("Version={0}; Build={1}; InstallDate={2}; Architecture={3}" -f $os.Version,$os.BuildNumber,$os.InstallDate,$os.OSArchitecture) -Source 'Win32_OperatingSystem'
                $rule = Get-CATRuleDecision -RuleId 'CORE-UPTIME-001' -Data @{ Days=$uptime.TotalDays } -Policy $policy
                Add-HealthResult -Category 'Operating System' -Check 'Uptime' -Target $server -Role $roleText -Value ("{0} days" -f $uptimeDays) -Status $rule.Status -Severity $rule.Severity -Impact $rule.Impact -Finding ("Last boot: {0}; Uptime: {1} days." -f $lastBoot.ToString('yyyy-MM-dd HH:mm:ss'),$uptimeDays) -Recommendation $rule.Recommendation -Evidence ("LastBoot={0}; UptimeDays={1}; HealthyMaxDays={2}; WarningMaxDays={3}; CriticalMinDays={4}" -f $lastBoot.ToString('yyyy-MM-dd HH:mm:ss'),$uptimeDays,$policy.Uptime.HealthyMaxDays,$policy.Uptime.WarningMaxDays,$policy.Uptime.CriticalMinDays) -Source 'Win32_OperatingSystem' -RuleId 'CORE-UPTIME-001'

                # Patch evidence: last installed KB and pending reboot. This is factual evidence, not a compliance score.
                try {
                    $qfes = @(Get-CimInstance -ComputerName $server -ClassName Win32_QuickFixEngineering -ErrorAction Stop | Where-Object { $_.HotFixID })
                    $qfeParsed = @($qfes | ForEach-Object {
                        [pscustomobject]@{ HotFixID = $_.HotFixID; InstalledOnRaw = $_.InstalledOn; InstalledOn = ConvertTo-CATDateTimeSafe $_.InstalledOn; Description = $_.Description }
                    } | Where-Object { $_.InstalledOn })
                    if($qfeParsed.Count -gt 0){
                        $lastKb = $qfeParsed | Sort-Object InstalledOn -Descending | Select-Object -First 1
                        $daysSincePatch = [math]::Round(((Get-Date) - $lastKb.InstalledOn).TotalDays, 1)
                        $patchRule = Get-CATRuleDecision -RuleId 'CORE-LASTPATCH-001' -Data @{ Days=$daysSincePatch } -Policy $policy
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Last Installed KB' -Target $server -Role $roleText -Value $lastKb.HotFixID -Status $patchRule.Status -Severity $patchRule.Severity -Impact $patchRule.Impact -Finding ("Last installed hotfix found: {0}." -f $lastKb.HotFixID) -Recommendation $patchRule.Recommendation -Evidence ("HotFixID={0}; Description={1}; InstalledOnRaw={2}" -f $lastKb.HotFixID,$lastKb.Description,$lastKb.InstalledOnRaw) -Source 'Win32_QuickFixEngineering' -RuleId 'CORE-LASTPATCH-001'
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Installed On' -Target $server -Role $roleText -Value ($lastKb.InstalledOn.ToString('yyyy-MM-dd HH:mm:ss')) -Status $patchRule.Status -Severity $patchRule.Severity -Impact $patchRule.Impact -Finding ("Last KB installation date: {0}." -f $lastKb.InstalledOn.ToString('yyyy-MM-dd HH:mm:ss')) -Recommendation $patchRule.Recommendation -Evidence ("InstalledOn={0}" -f $lastKb.InstalledOn.ToString('yyyy-MM-dd HH:mm:ss')) -Source 'Win32_QuickFixEngineering' -RuleId 'CORE-LASTPATCH-001'
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Days Since Last Patch' -Target $server -Role $roleText -Value ("{0} days" -f $daysSincePatch) -Status $patchRule.Status -Severity $patchRule.Severity -Impact $patchRule.Impact -Finding ("{0} day(s) since last installed KB evidence." -f $daysSincePatch) -Recommendation $patchRule.Recommendation -Evidence ("DaysSinceLastPatch={0}; HealthyMaxDays={1}; WarningMaxDays={2}; CriticalMinDays={3}" -f $daysSincePatch,$policy.Uptime.HealthyMaxDays,$policy.Uptime.WarningMaxDays,$policy.Uptime.CriticalMinDays) -Source 'Win32_QuickFixEngineering' -RuleId 'CORE-LASTPATCH-001'
                    } else {
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Last Installed KB' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'No installed KB date evidence was returned by Win32_QuickFixEngineering.' -Recommendation 'Validate Windows Update history manually if patch evidence is required.' -Evidence 'No dated QuickFixEngineering records.' -Source 'Win32_QuickFixEngineering'
                    }
                } catch {
                    Add-HealthResult -Category 'Patch Evidence' -Check 'Last Installed KB' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query installed KB evidence.' -Recommendation 'Validate remote permissions and Windows Update history manually if required.' -Evidence $_.Exception.Message -Source 'Win32_QuickFixEngineering'
                }

                try {
                    $reboot = Get-CATPendingRebootState -ComputerName $server
                    if($reboot.Pending){
                        $reasonText = (@($reboot.Reasons) -join '; ')
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Pending Reboot' -Target $server -Role $roleText -Value 'Yes' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'The server has pending reboot evidence.' -Recommendation 'Confirm maintenance window and reboot the server if appropriate.' -Evidence ("Reasons={0}" -f $reasonText) -Source 'Registry/Invoke-Command' -RuleId 'CORE-PENDINGREBOOT-001'
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Pending Reboot Reason' -Target $server -Role $roleText -Value $reasonText -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'Pending reboot reason(s) detected.' -Recommendation 'Review the pending reboot reasons before remediation.' -Evidence ("Reasons={0}" -f $reasonText) -Source 'Registry/Invoke-Command' -RuleId 'CORE-PENDINGREBOOT-001'
                    } else {
                        Add-HealthResult -Category 'Patch Evidence' -Check 'Pending Reboot' -Target $server -Role $roleText -Value 'No' -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'No common pending reboot registry indicators were detected.' -Recommendation 'No action required.' -Evidence 'No known pending reboot registry indicators found.' -Source 'Registry/Invoke-Command' -RuleId 'CORE-PENDINGREBOOT-001'
                    }
                } catch {
                    Add-HealthResult -Category 'Patch Evidence' -Check 'Pending Reboot' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to check pending reboot state.' -Recommendation 'Validate PowerShell remoting permissions and check pending reboot registry keys manually if required.' -Evidence $_.Exception.Message -Source 'Registry/Invoke-Command' -RuleId 'CORE-PENDINGREBOOT-001'
                }

                # Memory from OS object
                $totalGB = [math]::Round(($os.TotalVisibleMemorySize * 1KB) / 1GB, 2)
                $freeGB = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 2)
                $usedGB = [math]::Round($totalGB - $freeGB, 2)
                $usedPct = if($totalGB -gt 0){ [math]::Round(($usedGB / $totalGB) * 100, 2) } else { 0 }
                $freePct = [math]::Round(100 - $usedPct, 2)
                $memRule = Get-CATRuleDecision -RuleId 'CORE-MEMORY-001' -Data @{ UsedPct=$usedPct } -Policy $policy
                Add-HealthResult -Category 'Memory' -Check 'Physical Memory' -Target $server -Role $roleText -Value ("Used={0} GB ({1}%); Free={2} GB ({3}%)" -f $usedGB,$usedPct,$freeGB,$freePct) -Status $memRule.Status -Severity $memRule.Severity -Impact $memRule.Impact -Finding ("Total RAM {0} GB; used {1} GB ({2}%); free {3} GB ({4}%)." -f $totalGB,$usedGB,$usedPct,$freeGB,$freePct) -Recommendation $memRule.Recommendation -Evidence ("TotalGB={0}; UsedGB={1}; FreeGB={2}; UsedPct={3}; FreePct={4}" -f $totalGB,$usedGB,$freeGB,$usedPct,$freePct) -Source 'Win32_OperatingSystem' -RuleId 'CORE-MEMORY-001'
            } catch {
                Add-HealthResult -Category 'Operating System' -Check 'OS Inventory' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query operating system via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_OperatingSystem'
            }

            # CPU inventory and load
            try {
                $cpu = @(Get-CimInstance -ComputerName $server -ClassName Win32_Processor -ErrorAction Stop)
                if($cpu.Count -gt 0){
                    $sockets = $cpu.Count
                    $cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
                    $logical = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
                    $avgLoad = [math]::Round((($cpu | Measure-Object -Property LoadPercentage -Average).Average), 2)
                    $cpuName = (@($cpu | Select-Object -ExpandProperty Name -Unique) -join '; ')
                    $cpuRule = Get-CATRuleDecision -RuleId 'CORE-CPU-001' -Data @{ UsedPct=$avgLoad } -Policy $policy
                    Add-HealthResult -Category 'CPU' -Check 'CPU Inventory and Load' -Target $server -Role $roleText -Value ("Sockets={0}; Cores={1}; Logical={2}; Load={3}%" -f $sockets,$cores,$logical,$avgLoad) -Status $cpuRule.Status -Severity $cpuRule.Severity -Impact $cpuRule.Impact -Finding ("{0} socket(s), {1} core(s), {2} logical processor(s), current load {3}%." -f $sockets,$cores,$logical,$avgLoad) -Recommendation $cpuRule.Recommendation -Evidence ("Name={0}; Sockets={1}; Cores={2}; LogicalProcessors={3}; LoadPct={4}" -f $cpuName,$sockets,$cores,$logical,$avgLoad) -Source 'Win32_Processor' -RuleId 'CORE-CPU-001'
                }
            } catch {
                Add-HealthResult -Category 'CPU' -Check 'CPU Inventory and Load' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query CPU inventory via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_Processor'
            }

            # Storage
            try {
                $disks = @(Get-CimInstance -ComputerName $server -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
                foreach($disk in $disks){
                    if($disk.Size -gt 0){
                        $freePct = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
                        $usedPct = [math]::Round(100 - $freePct, 2)
                        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
                        $sizeGB = [math]::Round($disk.Size / 1GB, 2)
                        $usedGB = [math]::Round($sizeGB - $freeGB, 2)
                        $isIgnoredSystemVolume = (($disk.FileSystem -match 'FAT|FAT32') -and $sizeGB -lt 5) -or ($sizeGB -lt 3 -and $freePct -ge 90)
                        if($isIgnoredSystemVolume){
                            Add-HealthResult -Category 'Storage' -Check ("Disk {0}" -f $disk.DeviceID) -Target $server -Role $roleText -Value ("Total={0} GB; Used={1} GB; Free={2} GB; FreePct={3}%" -f $sizeGB,$usedGB,$freeGB,$freePct) -Status 'NotApplicable' -Severity 'Info' -Impact 'Low' -Finding ("Drive {0} ({1}) appears to be a small system/reserved volume and was ignored for capacity assessment." -f $disk.DeviceID,$disk.FileSystem) -Recommendation 'No action required.' -Evidence ("DeviceID={0}; FileSystem={1}; TotalGB={2}; UsedGB={3}; FreeGB={4}; UsedPct={5}; FreePct={6}; IgnoredReason=SmallSystemOrReservedVolume" -f $disk.DeviceID,$disk.FileSystem,$sizeGB,$usedGB,$freeGB,$usedPct,$freePct) -Source 'Win32_LogicalDisk' -RuleId 'CORE-DISK-001'
                        } else {
                            $rule = Get-CATRuleDecision -RuleId 'CORE-DISK-001' -Data @{ FreePct=$freePct; FreeGB=$freeGB } -Policy $policy
                            Add-HealthResult -Category 'Storage' -Check ("Disk {0}" -f $disk.DeviceID) -Target $server -Role $roleText -Value ("Total={0} GB; Used={1} GB; Free={2} GB; FreePct={3}%" -f $sizeGB,$usedGB,$freeGB,$freePct) -Status $rule.Status -Severity $rule.Severity -Impact $rule.Impact -Finding ("Drive {0} ({1}) has {2} GB free of {3} GB ({4}% free; {5}% used)." -f $disk.DeviceID,$disk.FileSystem,$freeGB,$sizeGB,$freePct,$usedPct) -Recommendation $rule.Recommendation -Evidence ("DeviceID={0}; FileSystem={1}; TotalGB={2}; UsedGB={3}; FreeGB={4}; UsedPct={5}; FreePct={6}" -f $disk.DeviceID,$disk.FileSystem,$sizeGB,$usedGB,$freeGB,$usedPct,$freePct) -Source 'Win32_LogicalDisk' -RuleId 'CORE-DISK-001'
                        }
                    }
                }
            } catch {
                Add-HealthResult -Category 'Storage' -Check 'Disk Inventory' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query logical disks via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_LogicalDisk'
            }

            # Services
            $servicesToCheck = @('Winmgmt','LanmanServer','RemoteRegistry')
            if($roleText -match 'Management Point|Distribution Point|Software Update Point|Reporting|Application Catalog|Enrollment') { $servicesToCheck += 'W3SVC' }
            if($roleText -match 'Distribution Point|Site Server|Component Server') { $servicesToCheck += 'SMS_EXECUTIVE' }
            if($roleText -match 'Software Update Point') { $servicesToCheck += 'WsusService' }
            $servicesToCheck = $servicesToCheck | Sort-Object -Unique
            foreach($svcName in $servicesToCheck){
                try {
                    $svcNameFilter = Escape-CimFilterValue $svcName
                    $svc = Get-CimInstance -ComputerName $server -ClassName Win32_Service -Filter "Name='$svcNameFilter'" -ErrorAction Stop
                    if($null -eq $svc){
                        Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Status 'NotApplicable' -Severity 'Info' -Impact 'Low' -Finding 'Service not present.' -Recommendation 'No action required if this service is not expected for this role.' -Evidence 'Not found' -Source 'Win32_Service'
                    } elseif($svc.State -eq 'Running'){
                        Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Value $svc.State -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'Service is running.' -Recommendation 'No action required.' -Evidence ("State={0}; StartMode={1}; DisplayName={2}" -f $svc.State,$svc.StartMode,$svc.DisplayName) -Source 'Win32_Service'
                    } else {
                        $expected = if($svc.StartMode -eq 'Auto'){'Critical'}else{'Warning'}
                        $sev = if($svc.StartMode -eq 'Auto'){'High'}else{'Medium'}
                        $impact = if($svc.StartMode -eq 'Auto'){'High'}else{'Medium'}
                        Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Value $svc.State -Status $expected -Severity $sev -Impact $impact -Finding ("Service is {0}." -f $svc.State) -Recommendation 'Validate the service state, event logs, and role-specific logs before remediation.' -Evidence ("State={0}; StartMode={1}; DisplayName={2}" -f $svc.State,$svc.StartMode,$svc.DisplayName) -Source 'Win32_Service'
                    }
                } catch {
                    Add-HealthResult -Category 'Services' -Check "Service $svcName" -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query service via CIM.' -Recommendation 'Validate remote CIM/WMI permissions and firewall.' -Evidence $_.Exception.Message -Source 'Win32_Service'
                }
            }
        } else {
            Add-HealthResult -Category 'Remote Checks' -Check 'CIM Dependent Checks' -Target $server -Role $roleText -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Skipped OS, CPU, memory, disk and service checks because WinRM failed.' -Recommendation 'Fix WinRM/connectivity/permissions to enable full Core Health assessment.' -Evidence 'WinRM unavailable' -Source 'CoreHealthEngine'
        }
        $serverSw.Stop()
        Add-HealthResult -Category 'Summary' -Check 'Server Core Health Completed' -Target $server -Role $roleText -Status 'Info' -Severity 'Info' -Impact 'Low' -Finding ("Core Health completed for server in {0:n1} seconds." -f $serverSw.Elapsed.TotalSeconds) -Evidence ("DurationSeconds={0:n2}" -f $serverSw.Elapsed.TotalSeconds) -Source 'CoreHealthEngine' -DurationSeconds $serverSw.Elapsed.TotalSeconds
    }

    Send-Progress 100 'Core Health completed.'
    $sw.Stop()
    $coreResults = @($Session.Results | Where-Object Module -eq 'CoreHealth')
    $scoredResults = @($coreResults | Where-Object { $_.Status -in @('Healthy','Warning','Critical','UnableToCheck') })
    $penalty = 0
    foreach($r in $scoredResults){
        switch($r.Status){
            'Critical' { $penalty += 10; break }
            'Warning' { $penalty += 4; break }
            'UnableToCheck' { $penalty += 3; break }
        }
    }
    $maxPenalty = [math]::Max(1, $scoredResults.Count * 10)
    $healthScore = [math]::Max(0, [math]::Round(100 - (($penalty / $maxPenalty) * 100), 2))
    $summary = [ordered]@{
        Servers = $servers.Count
        Healthy = @($coreResults | Where-Object Status -eq 'Healthy').Count
        Warning = @($coreResults | Where-Object Status -eq 'Warning').Count
        Critical = @($coreResults | Where-Object Status -eq 'Critical').Count
        UnableToCheck = @($coreResults | Where-Object Status -eq 'UnableToCheck').Count
        HealthScore = $healthScore
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds,2)
    }
    $Session.Inventory.CoreHealth = $summary
    $Session.Inventory.HealthScore = $healthScore
    Add-HealthResult -Category 'Summary' -Check 'Core Health Completed' -Status 'Info' -Finding ("Core Health completed for $($servers.Count) server(s). Health Score: $healthScore%.") -Value ("HealthScore={0}%" -f $healthScore) -Evidence ("Healthy={0}; Warning={1}; Critical={2}; UnableToCheck={3}; HealthScore={4}" -f $summary.Healthy,$summary.Warning,$summary.Critical,$summary.UnableToCheck,$summary.HealthScore)
    Send-Log ("Core Health completed. Servers={0}; Healthy={1}; Warning={2}; Critical={3}; UnableToCheck={4}; HealthScore={5}%; Duration={6:n1}s" -f $summary.Servers,$summary.Healthy,$summary.Warning,$summary.Critical,$summary.UnableToCheck,$summary.HealthScore,$sw.Elapsed.TotalSeconds)
    return $summary
}
Export-ModuleMember -Function *
