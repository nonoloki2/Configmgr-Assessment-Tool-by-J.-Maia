function Invoke-CATManagementPointAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [scriptblock]$ProgressCallback,
        [scriptblock]$LogCallback
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    function Send-Progress([int]$Percent,[string]$Task){ if($ProgressCallback){ & $ProgressCallback $Percent $Task } }
    function Send-Log([string]$Msg,[string]$Level='INFO'){ if($LogCallback){ & $LogCallback $Msg $Level }; Write-CATLog -Session $Session -Level $Level -Category 'ManagementPoint' -Message $Msg | Out-Null }
    function Add-MPResult {
        param(
            [string]$Category,
            [string]$Check,
            [string]$Target,
            [string]$Value='',
            [string]$Status='Info',
            [string]$Severity='Info',
            [string]$Impact='Low',
            [string]$Finding='',
            [string]$Recommendation='',
            [string]$Evidence='',
            [string]$Source='ManagementPoint',
            [string]$RuleId='',
            [double]$DurationSeconds=0
        )
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'ManagementPoint' -Category $Category -Check $Check -Target $Target -Role 'SMS Management Point' -Value $Value -Status $Status -Severity $Severity -Impact $Impact -Finding $Finding -Recommendation $Recommendation -Evidence $Evidence -Source $Source -RuleId $RuleId -DurationSeconds $DurationSeconds) | Out-Null
    }
    function Get-WorstStatusLocal {
        param([object[]]$Items)
        $rank = @{ Critical=5; Warning=4; UnableToCheck=3; Healthy=2; Info=1; NotApplicable=0 }
        $worst='Info'; $n=-1
        foreach($i in @($Items)){ $r = if($rank.ContainsKey($i.Status)){ $rank[$i.Status] } else { 0 }; if($r -gt $n){ $n=$r; $worst=$i.Status } }
        return $worst
    }

    $mpServers = @($Session.Inventory.Roles | Where-Object { $_.RoleName -like '*Management Point*' } | Select-Object -ExpandProperty ServerName -Unique | Sort-Object)
    if(-not $mpServers -or $mpServers.Count -eq 0){
        Add-MPResult -Category 'Summary' -Check 'Management Points Found' -Target '' -Value '0' -Status 'NotApplicable' -Finding 'No Management Point role was discovered.' -Recommendation 'No action required if this is expected.' -Evidence 'Discovery did not return SMS Management Point roles.' -Source 'SMS_SystemResourceList'
        return [pscustomobject]@{ ManagementPoints=0; Healthy=0; Warning=0; Critical=0; UnableToCheck=0; DurationSeconds=[math]::Round($sw.Elapsed.TotalSeconds,1) }
    }

    Send-Log ("Starting Management Point assessment for {0} server(s)." -f $mpServers.Count)
    Add-MPResult -Category 'Summary' -Check 'MP Connectivity, Services and IIS Prerequisites Started' -Target '' -Value ("{0} MP server(s)" -f $mpServers.Count) -Status 'Info' -Finding 'Management Point assessment started.' -Evidence ($mpServers -join '; ') -Source 'DiscoveryInventory'

    $index = 0
    foreach($server in $mpServers){
        $index++
        $basePct = [int](($index-1) / [math]::Max($mpServers.Count,1) * 100)
        Send-Progress $basePct ("Assessing MP {0} ({1}/{2})" -f $server,$index,$mpServers.Count)
        Send-Log "Assessing MP: $server"
        $serverStart = [System.Diagnostics.Stopwatch]::StartNew()

        Add-MPResult -Category 'Role' -Check 'Role Discovered' -Target $server -Value 'SMS Management Point' -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'Management Point role was discovered for this server.' -Recommendation 'No action required.' -Evidence 'RoleName=SMS Management Point' -Source 'SMS_SystemResourceList' -RuleId 'MP-ROLE-001'

        # DNS
        try {
            $dns = [System.Net.Dns]::GetHostEntry($server)
            $ips = @($dns.AddressList | ForEach-Object { $_.IPAddressToString }) -join '; '
            Add-MPResult -Category 'Connectivity' -Check 'DNS Resolve' -Target $server -Value $ips -Status 'Healthy' -Finding 'DNS resolution succeeded.' -Recommendation 'No action required.' -Evidence ("HostName={0}; IP={1}" -f $dns.HostName,$ips) -Source 'System.Net.Dns' -RuleId 'MP-CONN-001'
        } catch {
            Add-MPResult -Category 'Connectivity' -Check 'DNS Resolve' -Target $server -Value 'Failed' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'DNS resolution failed.' -Recommendation 'Validate DNS registration and the server name discovered by ConfigMgr.' -Evidence $_.Exception.Message -Source 'System.Net.Dns' -RuleId 'MP-CONN-001'
        }

        # Ping
        try {
            $pings = @(Test-Connection -ComputerName $server -Count 2 -ErrorAction Stop)
            $avg = [math]::Round((($pings | Measure-Object -Property ResponseTime -Average).Average),2)
            if([double]::IsNaN($avg)){ $avg = 0 }
            Add-MPResult -Category 'Connectivity' -Check 'Ping' -Target $server -Value ("Avg={0}ms; Loss=0%" -f $avg) -Status 'Healthy' -Finding 'Ping succeeded.' -Recommendation 'No action required.' -Evidence ("Replies={0}; Avg={1}ms" -f $pings.Count,$avg) -Source 'Test-Connection' -RuleId 'MP-CONN-002'
        } catch {
            Add-MPResult -Category 'Connectivity' -Check 'Ping' -Target $server -Value 'Failed' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'Ping failed or ICMP is blocked.' -Recommendation 'Validate network path. ICMP may be blocked; continue with WinRM and HTTP tests.' -Evidence $_.Exception.Message -Source 'Test-Connection' -RuleId 'MP-CONN-002'
        }

        # WinRM / CIM
        $cimAvailable = $false
        try {
            $wrmSw = [System.Diagnostics.Stopwatch]::StartNew()
            Test-WSMan -ComputerName $server -ErrorAction Stop | Out-Null
            $wrmSw.Stop()
            $cimAvailable = $true
            Add-MPResult -Category 'Connectivity' -Check 'WinRM' -Target $server -Value ("{0} ms" -f $wrmSw.ElapsedMilliseconds) -Status 'Healthy' -Finding 'WinRM is available.' -Recommendation 'No action required.' -Evidence ("Test-WSMan succeeded in {0} ms." -f $wrmSw.ElapsedMilliseconds) -Source 'Test-WSMan' -RuleId 'MP-CONN-003'
        } catch {
            Add-MPResult -Category 'Connectivity' -Check 'WinRM' -Target $server -Value 'Failed' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'WinRM is not available.' -Recommendation 'Enable/validate WinRM or run the assessment from a context allowed to connect remotely.' -Evidence $_.Exception.Message -Source 'Test-WSMan' -RuleId 'MP-CONN-003'
        }

        if($cimAvailable){
            # Services
            foreach($svcName in @('SMS_EXECUTIVE','SMS_SITE_COMPONENT_MANAGER','W3SVC','Winmgmt','RemoteRegistry','BITS')){
                try {
                    $filter = "Name='$svcName'"
                    $svc = Get-CimInstance -ComputerName $server -ClassName Win32_Service -Filter $filter -ErrorAction Stop
                    if($null -eq $svc){ throw "Service $svcName not found." }
                    if($svc.State -eq 'Running'){
                        Add-MPResult -Category 'Services' -Check ("Service {0}" -f $svcName) -Target $server -Value $svc.State -Status 'Healthy' -Finding 'Required service is running.' -Recommendation 'No action required.' -Evidence ("Name={0}; State={1}; StartMode={2}" -f $svc.Name,$svc.State,$svc.StartMode) -Source 'Win32_Service' -RuleId 'MP-SVC-001'
                    } else {
                        $sev = if($svcName -in @('SMS_EXECUTIVE','W3SVC')){'High'}else{'Medium'}
                        $status = if($svcName -in @('SMS_EXECUTIVE','W3SVC')){'Critical'}else{'Warning'}
                        Add-MPResult -Category 'Services' -Check ("Service {0}" -f $svcName) -Target $server -Value $svc.State -Status $status -Severity $sev -Impact $sev -Finding 'Required service is not running.' -Recommendation 'Start the service and review related Windows/System and ConfigMgr logs.' -Evidence ("Name={0}; State={1}; StartMode={2}" -f $svc.Name,$svc.State,$svc.StartMode) -Source 'Win32_Service' -RuleId 'MP-SVC-001'
                    }
                } catch {
                    Add-MPResult -Category 'Services' -Check ("Service {0}" -f $svcName) -Target $server -Value 'UnableToCheck' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query required service.' -Recommendation 'Validate CIM permissions and remote service query access.' -Evidence $_.Exception.Message -Source 'Win32_Service' -RuleId 'MP-SVC-001'
                }
            }


            # IIS prerequisites based on Microsoft ConfigMgr MP prerequisites
            try {
                $iisPrereq = Invoke-Command -ComputerName $server -ScriptBlock {
                    $featureNames = @('Web-Server','Web-Windows-Auth','Web-ISAPI-Ext','Web-Metabase','Web-WMI')
                    $features = @()
                    if(Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue){
                        $features = @(Get-WindowsFeature -Name $featureNames -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Installed=[bool]$_.Installed; DisplayName=$_.DisplayName } })
                    }
                    Import-Module WebAdministration -ErrorAction SilentlyContinue
                    $verbs = @('GET','POST','CCM_POST','HEAD','PROPFIND')
                    $allowed = @()
                    foreach($verb in $verbs){
                        $found = $null
                        try { $found = Get-WebConfigurationProperty -Filter "system.webServer/security/requestFiltering/verbs/add[@verb='$verb']" -Name allowed -PSPath 'MACHINE/WEBROOT/APPHOST' -ErrorAction SilentlyContinue } catch {}
                        $allowed += [pscustomobject]@{ Verb=$verb; Allowed= if($null -eq $found){ $true } else { [bool]$found.Value } }
                    }
                    [pscustomobject]@{ Features=$features; Verbs=$allowed }
                } -ErrorAction Stop

                $requiredFeatures = @('Web-Server','Web-Windows-Auth','Web-ISAPI-Ext','Web-Metabase','Web-WMI')
                foreach($feature in $requiredFeatures){
                    $f = @($iisPrereq.Features | Where-Object Name -eq $feature | Select-Object -First 1)
                    if($f -and $f.Installed){
                        Add-MPResult -Category 'IIS Prerequisites' -Check ("Feature {0}" -f $feature) -Target $server -Value 'Installed' -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'Required IIS feature is installed.' -Recommendation 'No action required.' -Evidence ("Name={0}; Installed=True" -f $feature) -Source 'Get-WindowsFeature' -RuleId 'MP-IIS-PREREQ-001'
                    } elseif($f) {
                        Add-MPResult -Category 'IIS Prerequisites' -Check ("Feature {0}" -f $feature) -Target $server -Value 'NotInstalled' -Status 'Critical' -Severity 'High' -Impact 'High' -Finding 'Required IIS feature for Management Point is not installed.' -Recommendation 'Install the missing IIS prerequisite and review MPSetup.log/mpMSI.log if the Management Point installation is unhealthy.' -Evidence ("Name={0}; Installed=False" -f $feature) -Source 'Get-WindowsFeature' -RuleId 'MP-IIS-PREREQ-001'
                    } else {
                        Add-MPResult -Category 'IIS Prerequisites' -Check ("Feature {0}" -f $feature) -Target $server -Value 'UnableToCheck' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to determine IIS feature installation state.' -Recommendation 'Validate remote PowerShell permissions and Windows Server feature query availability.' -Evidence ("Name={0}; Get-WindowsFeature did not return data." -f $feature) -Source 'Get-WindowsFeature' -RuleId 'MP-IIS-PREREQ-001'
                    }
                }
                foreach($verb in @($iisPrereq.Verbs)){
                    if($verb.Allowed){
                        Add-MPResult -Category 'IIS Prerequisites' -Check ("HTTP Verb {0}" -f $verb.Verb) -Target $server -Value 'Allowed' -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'Required HTTP verb is allowed or not explicitly denied.' -Recommendation 'No action required.' -Evidence ("Verb={0}; Allowed=True" -f $verb.Verb) -Source 'IIS RequestFiltering' -RuleId 'MP-IIS-VERB-001'
                    } else {
                        Add-MPResult -Category 'IIS Prerequisites' -Check ("HTTP Verb {0}" -f $verb.Verb) -Target $server -Value 'Denied' -Status 'Critical' -Severity 'High' -Impact 'High' -Finding 'Required HTTP verb appears to be denied in IIS request filtering.' -Recommendation 'Allow required ConfigMgr client communication verbs: GET, POST, CCM_POST, HEAD and PROPFIND.' -Evidence ("Verb={0}; Allowed=False" -f $verb.Verb) -Source 'IIS RequestFiltering' -RuleId 'MP-IIS-VERB-001'
                    }
                }
            } catch {
                Add-MPResult -Category 'IIS Prerequisites' -Check 'IIS Prerequisite Query' -Target $server -Value 'UnableToCheck' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query IIS prerequisite configuration remotely.' -Recommendation 'Validate remote PowerShell permissions, IIS management tooling and WebAdministration module availability.' -Evidence $_.Exception.Message -Source 'Invoke-Command/WebAdministration' -RuleId 'MP-IIS-PREREQ-000'
            }

            # IIS App Pools and bindings
            try {
                $iis = Invoke-Command -ComputerName $server -ScriptBlock {
                    Import-Module WebAdministration -ErrorAction Stop
                    $pools = @(Get-ChildItem IIS:\AppPools | Where-Object { $_.Name -match 'SMS|CCM|Management|MP' } | ForEach-Object { [pscustomobject]@{ Name=$_.Name; State=$_.State } })
                    $bindings = @(Get-WebBinding | ForEach-Object { [pscustomobject]@{ Protocol=$_.protocol; BindingInformation=$_.bindingInformation; SslFlags=$_.sslFlags } })
                    [pscustomobject]@{ AppPools=$pools; Bindings=$bindings }
                } -ErrorAction Stop
                if($iis.AppPools -and @($iis.AppPools).Count -gt 0){
                    foreach($pool in @($iis.AppPools)){
                        $state = [string]$pool.State
                        if($state -eq 'Started'){
                            Add-MPResult -Category 'IIS' -Check ("App Pool {0}" -f $pool.Name) -Target $server -Value $state -Status 'Healthy' -Finding 'IIS application pool is started.' -Recommendation 'No action required.' -Evidence ("AppPool={0}; State={1}" -f $pool.Name,$state) -Source 'WebAdministration' -RuleId 'MP-IIS-001'
                        } else {
                            Add-MPResult -Category 'IIS' -Check ("App Pool {0}" -f $pool.Name) -Target $server -Value $state -Status 'Critical' -Severity 'High' -Impact 'High' -Finding 'IIS application pool is not started.' -Recommendation 'Start the application pool and review IIS event logs and MPControl.log.' -Evidence ("AppPool={0}; State={1}" -f $pool.Name,$state) -Source 'WebAdministration' -RuleId 'MP-IIS-001'
                        }
                    }
                } else {
                    Add-MPResult -Category 'IIS' -Check 'ConfigMgr MP App Pools' -Target $server -Value 'No matching app pools found' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'No IIS application pools matching SMS/CCM/MP were found.' -Recommendation 'Validate IIS role, Management Point installation and app pool names.' -Evidence 'Filter=SMS|CCM|Management|MP' -Source 'WebAdministration' -RuleId 'MP-IIS-001'
                }
                $bindingText = (@($iis.Bindings) | ForEach-Object { "{0}:{1}" -f $_.Protocol,$_.BindingInformation }) -join '; '
                Add-MPResult -Category 'IIS' -Check 'IIS Bindings' -Target $server -Value $bindingText -Status 'Info' -Severity 'Info' -Impact 'Low' -Finding 'IIS bindings collected.' -Recommendation 'Review HTTP/HTTPS bindings against the intended client communication mode.' -Evidence $bindingText -Source 'WebAdministration' -RuleId 'MP-IIS-002'
            } catch {
                Add-MPResult -Category 'IIS' -Check 'IIS Configuration' -Target $server -Value 'UnableToCheck' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query IIS configuration remotely.' -Recommendation 'Validate WebAdministration module availability and remote PowerShell permissions.' -Evidence $_.Exception.Message -Source 'WebAdministration' -RuleId 'MP-IIS-001'
            }

            # Certificates expiring soon for local machine personal store
            try {
                $certSummary = Invoke-Command -ComputerName $server -ScriptBlock {
                    $now = Get-Date
                    $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt $now } | Sort-Object NotAfter | Select-Object -First 5 Subject,Thumbprint,NotAfter)
                    $soon = @($certs | Where-Object { $_.NotAfter -lt $now.AddDays(30) })
                    [pscustomobject]@{ Certs=$certs; ExpiringSoon=$soon.Count }
                } -ErrorAction Stop
                $certText = (@($certSummary.Certs) | ForEach-Object { "{0} exp={1}" -f $_.Subject, ([datetime]$_.NotAfter).ToString('yyyy-MM-dd') }) -join '; '
                if([int]$certSummary.ExpiringSoon -gt 0){
                    Add-MPResult -Category 'Certificates' -Check 'Machine Certificates' -Target $server -Value ("{0} certificate(s) expiring within 30 days" -f $certSummary.ExpiringSoon) -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'One or more machine certificates expire within 30 days.' -Recommendation 'Review IIS/client authentication certificates and renew before expiration.' -Evidence $certText -Source 'Cert:\LocalMachine\My' -RuleId 'MP-CERT-001'
                } else {
                    Add-MPResult -Category 'Certificates' -Check 'Machine Certificates' -Target $server -Value 'No near-term expiration detected' -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'No machine certificate expiring within 30 days was detected in the sampled certificates.' -Recommendation 'No action required.' -Evidence $certText -Source 'Cert:\LocalMachine\My' -RuleId 'MP-CERT-001'
                }
            } catch {
                Add-MPResult -Category 'Certificates' -Check 'Machine Certificates' -Target $server -Value 'UnableToCheck' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to query certificate store.' -Recommendation 'Validate remote PowerShell permissions and certificate provider access.' -Evidence $_.Exception.Message -Source 'Cert:\LocalMachine\My' -RuleId 'MP-CERT-001'
            }

            # MPControl.log evidence
            try {
                $logInfo = Invoke-Command -ComputerName $server -ScriptBlock {
                    $candidates = New-Object System.Collections.Generic.List[string]
                    try {
                        $id = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction Stop
                        if($id.'Installation Directory') { $candidates.Add((Join-Path $id.'Installation Directory' 'Logs\MPControl.log')) }
                    } catch {}
                    $candidates.Add('C:\Program Files\Microsoft Configuration Manager\Logs\MPControl.log')
                    $candidates.Add('C:\SMS_CCM\Logs\MPControl.log')
                    $path = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                    if(-not $path){ return [pscustomobject]@{ Found=$false; Path=''; Summary='MPControl.log was not found.' } }
                    $tail = @(Get-Content -LiteralPath $path -Tail 120 -ErrorAction Stop)
                    $bad = @($tail | Where-Object { $_ -match '(?i)error|failed|unhealthy|status code 5|status code 4|not responding' })
                    $good = @($tail | Where-Object { $_ -match '(?i)success|healthy|successfully' })
                    [pscustomobject]@{ Found=$true; Path=$path; BadCount=$bad.Count; GoodCount=$good.Count; Sample=(($bad | Select-Object -Last 3) -join ' || ') }
                } -ErrorAction Stop
                if(-not $logInfo.Found){
                    Add-MPResult -Category 'Logs' -Check 'MPControl.log' -Target $server -Value 'Not found' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'MPControl.log was not found in common locations.' -Recommendation 'Validate ConfigMgr installation path and MP role installation.' -Evidence $logInfo.Summary -Source 'MPControl.log' -RuleId 'MP-LOG-001'
                } elseif([int]$logInfo.BadCount -gt 0){
                    Add-MPResult -Category 'Logs' -Check 'MPControl.log' -Target $server -Value ("{0} suspicious line(s) in last 120 lines" -f $logInfo.BadCount) -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'MPControl.log contains recent warning/error indicators.' -Recommendation 'Review MPControl.log and correlate with IIS, certificates and MP availability tests.' -Evidence ("Path={0}; Sample={1}" -f $logInfo.Path,$logInfo.Sample) -Source 'MPControl.log' -RuleId 'MP-LOG-001'
                } else {
                    Add-MPResult -Category 'Logs' -Check 'MPControl.log' -Target $server -Value 'No recent error indicators' -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'No recent error indicators found in MPControl.log tail.' -Recommendation 'No action required.' -Evidence ("Path={0}; GoodLines={1}" -f $logInfo.Path,$logInfo.GoodCount) -Source 'MPControl.log' -RuleId 'MP-LOG-001'
                }
            } catch {
                Add-MPResult -Category 'Logs' -Check 'MPControl.log' -Target $server -Value 'UnableToCheck' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'Unable to read MPControl.log remotely.' -Recommendation 'Validate admin share/remote PowerShell permissions and log path.' -Evidence $_.Exception.Message -Source 'MPControl.log' -RuleId 'MP-LOG-001'
            }
        } else {
            Add-MPResult -Category 'Remote Checks' -Check 'CIM Dependent Checks' -Target $server -Value 'Skipped' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'Medium' -Finding 'CIM/WinRM dependent MP checks were skipped.' -Recommendation 'Restore WinRM/CIM connectivity and rerun MP assessment.' -Evidence 'WinRM unavailable.' -Source 'ManagementPointEngine' -RuleId 'MP-CONN-003'
        }

        # Live MP URL tests from current machine
        foreach($scheme in @('http','https')){
            $url = "${scheme}://$server/sms_mp/.sms_aut?mplist"
            try {
                $webSw = [System.Diagnostics.Stopwatch]::StartNew()
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $webSw.Stop()
                Add-MPResult -Category 'Live Test' -Check ("MPList URL {0}" -f $scheme.ToUpperInvariant()) -Target $server -Value ("HTTP {0}; {1} ms" -f [int]$resp.StatusCode,$webSw.ElapsedMilliseconds) -Status 'Healthy' -Severity 'Info' -Impact 'Low' -Finding 'MPList URL responded successfully.' -Recommendation 'No action required.' -Evidence $url -Source 'Invoke-WebRequest' -RuleId 'MP-URL-001'
            } catch {
                $status = if($scheme -eq 'http'){'Warning'}else{'Info'}
                $sev = if($scheme -eq 'http'){'Medium'}else{'Info'}
                Add-MPResult -Category 'Live Test' -Check ("MPList URL {0}" -f $scheme.ToUpperInvariant()) -Target $server -Value 'Failed' -Status $status -Severity $sev -Impact $(if($scheme -eq 'http'){'Medium'}else{'Low'}) -Finding ("Unable to access MPList URL over $scheme from the assessment workstation.") -Recommendation 'Validate client communication mode, IIS bindings, firewall and certificate trust. HTTPS failure may be expected if the environment is HTTP-only or certificate trust is unavailable.' -Evidence ("URL={0}; Error={1}" -f $url,$_.Exception.Message) -Source 'Invoke-WebRequest' -RuleId 'MP-URL-001'
            }
        }

        $serverStart.Stop()
        $srvMpResults = @($Session.Results | Where-Object { $_.Module -eq 'ManagementPoint' -and $_.Target -eq $server })
        $worst = Get-WorstStatusLocal $srvMpResults
        Add-MPResult -Category 'Summary' -Check 'MP Assessment Completed' -Target $server -Value $worst -Status $worst -Severity $(if($worst -eq 'Critical'){'High'}elseif($worst -eq 'Warning'){'Medium'}elseif($worst -eq 'UnableToCheck'){'Medium'}else{'Info'}) -Impact $(if($worst -eq 'Critical'){'High'}elseif($worst -eq 'Warning'){'Medium'}else{'Low'}) -Finding ("Management Point assessment completed with overall status: {0}." -f $worst) -Recommendation 'Review non-healthy findings for this Management Point.' -Evidence ("Duration={0:n1}s" -f $serverStart.Elapsed.TotalSeconds) -Source 'ManagementPointEngine' -RuleId 'MP-SUMMARY-001'
    }

    Send-Progress 100 'Management Point assessment completed.'
    $sw.Stop()
    $mpResults = @($Session.Results | Where-Object Module -eq 'ManagementPoint')
    $summary = [pscustomobject]@{
        ManagementPoints = $mpServers.Count
        Healthy = @($mpResults | Where-Object Status -eq 'Healthy').Count
        Warning = @($mpResults | Where-Object Status -eq 'Warning').Count
        Critical = @($mpResults | Where-Object Status -eq 'Critical').Count
        UnableToCheck = @($mpResults | Where-Object Status -eq 'UnableToCheck').Count
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
    }
    Send-Log ("Management Point assessment completed. MPs={0}; Healthy={1}; Warning={2}; Critical={3}; Unable={4}; Duration={5}s" -f $summary.ManagementPoints,$summary.Healthy,$summary.Warning,$summary.Critical,$summary.UnableToCheck,$summary.DurationSeconds)
    return $summary
}
Export-ModuleMember -Function *
