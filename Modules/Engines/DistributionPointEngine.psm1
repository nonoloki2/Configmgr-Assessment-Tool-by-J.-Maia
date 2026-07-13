function Invoke-CATDistributionPointAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Session,
        [scriptblock]$ProgressCallback,
        [scriptblock]$LogCallback
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    function Send-Progress([int]$Percent,[string]$Task){ if($ProgressCallback){ & $ProgressCallback $Percent $Task } }
    function Send-Log([string]$Msg,[string]$Level='INFO'){
        if($LogCallback){ & $LogCallback $Msg $Level }
        Write-CATLog -Session $Session -Level $Level -Category 'DistributionPoint' -Message $Msg | Out-Null
    }
    function Add-DPResult {
        param(
            [string]$Category,[string]$Check,[string]$Target,[string]$Value='',
            [string]$Status='Info',[string]$Severity='Info',[string]$Impact='Low',
            [string]$Finding='',[string]$Recommendation='',[string]$Evidence='',
            [string]$Source='DistributionPoint',[string]$RuleId='',[double]$DurationSeconds=0
        )
        Add-CATResult -Session $Session -Result (New-CATResult -AssessmentID $Session.AssessmentID -Module 'DistributionPoint' -Category $Category -Check $Check -Target $Target -Role 'SMS Distribution Point' -Value $Value -Status $Status -Severity $Severity -Impact $Impact -Finding $Finding -Recommendation $Recommendation -Evidence $Evidence -Source $Source -RuleId $RuleId -DurationSeconds $DurationSeconds) | Out-Null
    }
    function Get-WorstStatusLocal {
        param([object[]]$Items)
        $rank = @{ Critical=5; Warning=4; UnableToCheck=3; Healthy=2; Info=1; NotApplicable=0 }
        $worst='Info'; $n=-1
        foreach($i in @($Items)){
            $r = if($rank.ContainsKey([string]$i.Status)){ $rank[[string]$i.Status] } else { 0 }
            if($r -gt $n){ $n=$r; $worst=[string]$i.Status }
        }
        return $worst
    }

    $dpServers = @($Session.Inventory.Roles | Where-Object { $_.RoleName -like '*Distribution Point*' } | Select-Object -ExpandProperty ServerName -Unique | Sort-Object)
    if(-not $dpServers -or $dpServers.Count -eq 0){
        Add-DPResult -Category 'Summary' -Check 'Distribution Points Found' -Target '' -Value '0' -Status 'NotApplicable' -Finding 'No Distribution Point role was discovered.' -Recommendation 'No action required if this is expected.' -Evidence 'Discovery did not return SMS Distribution Point roles.' -Source 'SMS_SystemResourceList' -RuleId 'DP-DISC-001'
        return [pscustomobject]@{ DistributionPoints=0; Healthy=0; Warning=0; Critical=0; UnableToCheck=0; DurationSeconds=[math]::Round($sw.Elapsed.TotalSeconds,1) }
    }

    Send-Log ("Starting Distribution Point assessment for {0} server(s)." -f $dpServers.Count)
    $serverSummaries = New-Object System.Collections.ArrayList
    $index = 0

    foreach($server in $dpServers){
        $index++
        $base = [math]::Floor((($index-1) / [math]::Max(1,$dpServers.Count)) * 100)
        Send-Progress $base ("Distribution Point {0}/{1}: {2}" -f $index,$dpServers.Count,$server)
        Send-Log "Assessing Distribution Point: $server"
        $startResultCount = $Session.Results.Count

        # DNS
        try {
            $dns = [System.Net.Dns]::GetHostEntry($server)
            $addresses = @($dns.AddressList | ForEach-Object { $_.IPAddressToString }) -join ', '
            Add-DPResult -Category 'Connectivity' -Check 'DNS Resolution' -Target $server -Value $addresses -Status 'Healthy' -Finding 'DNS resolution succeeded.' -Recommendation 'No action required.' -Evidence ("Host={0}; Addresses={1}" -f $dns.HostName,$addresses) -Source 'System.Net.Dns' -RuleId 'DP-CONN-001'
        } catch {
            Add-DPResult -Category 'Connectivity' -Check 'DNS Resolution' -Target $server -Status 'Critical' -Severity 'High' -Impact 'High' -Finding 'DNS resolution failed.' -Recommendation 'Validate the DP DNS record, suffix search list and name resolution from the assessment workstation.' -Evidence $_.Exception.Message -Source 'System.Net.Dns' -RuleId 'DP-CONN-001'
        }

        # Ping: warning only because ICMP can be blocked
        try {
            $ping = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction Stop
            if($ping){
                Add-DPResult -Category 'Connectivity' -Check 'Ping' -Target $server -Value 'Responding' -Status 'Healthy' -Finding 'The server responded to ICMP.' -Recommendation 'No action required.' -Evidence 'Test-Connection returned True.' -Source 'Test-Connection' -RuleId 'DP-CONN-002'
            } else {
                Add-DPResult -Category 'Connectivity' -Check 'Ping' -Target $server -Value 'No response' -Status 'Warning' -Severity 'Low' -Impact 'Medium' -Finding 'The server did not respond to ICMP.' -Recommendation 'ICMP may be blocked. Validate CIM/WinRM and the network path before considering the DP unavailable.' -Evidence 'Test-Connection returned False.' -Source 'Test-Connection' -RuleId 'DP-CONN-002'
            }
        } catch {
            Add-DPResult -Category 'Connectivity' -Check 'Ping' -Target $server -Value 'Unable to test' -Status 'Warning' -Severity 'Low' -Impact 'Medium' -Finding 'Ping test could not be completed.' -Recommendation 'Validate network path or ICMP policy.' -Evidence $_.Exception.Message -Source 'Test-Connection' -RuleId 'DP-CONN-002'
        }

        $cim = $null
        try {
            $cim = New-CimSession -ComputerName $server -ErrorAction Stop
            Add-DPResult -Category 'Connectivity' -Check 'CIM Session' -Target $server -Value 'Connected' -Status 'Healthy' -Finding 'Remote CIM connection succeeded.' -Recommendation 'No action required.' -Evidence 'New-CimSession succeeded.' -Source 'CIM' -RuleId 'DP-CONN-003'
        } catch {
            Add-DPResult -Category 'Connectivity' -Check 'CIM Session' -Target $server -Value 'Failed' -Status 'UnableToCheck' -Severity 'Medium' -Impact 'High' -Finding 'Remote CIM connection failed; operating system checks for this DP were skipped.' -Recommendation 'Validate WinRM/CIM firewall rules, permissions, DNS and remote management configuration.' -Evidence $_.Exception.Message -Source 'CIM' -RuleId 'DP-CONN-003'
        }

        if($cim){
            try {
                foreach($serviceName in @('W3SVC','SMS_EXECUTIVE')){
                    $svc = Get-CimInstance -CimSession $cim -ClassName Win32_Service -Filter ("Name='{0}'" -f $serviceName) -ErrorAction Stop
                    if($svc){
                        $isRunning = ([string]$svc.State -eq 'Running')
                        Add-DPResult -Category 'Services' -Check $serviceName -Target $server -Value ("State={0}; StartMode={1}" -f $svc.State,$svc.StartMode) -Status $(if($isRunning){'Healthy'}else{'Critical'}) -Severity $(if($isRunning){'Info'}else{'High'}) -Impact $(if($isRunning){'Low'}else{'High'}) -Finding $(if($isRunning){"Service $serviceName is running."}else{"Service $serviceName is not running."}) -Recommendation $(if($isRunning){'No action required.'}else{"Start $serviceName and investigate the related Windows and ConfigMgr logs."}) -Evidence ("Name={0}; State={1}; StartMode={2}" -f $svc.Name,$svc.State,$svc.StartMode) -Source 'Win32_Service' -RuleId $(if($serviceName -eq 'W3SVC'){'DP-SVC-001'}else{'DP-SVC-002'})
                    } else {
                        $status = if($serviceName -eq 'W3SVC'){'Critical'}else{'NotApplicable'}
                        Add-DPResult -Category 'Services' -Check $serviceName -Target $server -Value 'Not found' -Status $status -Severity $(if($status -eq 'Critical'){'High'}else{'Info'}) -Impact $(if($status -eq 'Critical'){'High'}else{'Low'}) -Finding "Service $serviceName was not found." -Recommendation $(if($serviceName -eq 'W3SVC'){'Install/repair IIS for the Distribution Point role.'}else{'SMS_EXECUTIVE is expected only when the server also hosts a site server role.'}) -Evidence 'Win32_Service returned no instance.' -Source 'Win32_Service' -RuleId $(if($serviceName -eq 'W3SVC'){'DP-SVC-001'}else{'DP-SVC-002'})
                    }
                }
            } catch {
                Add-DPResult -Category 'Services' -Check 'Required Services' -Target $server -Status 'UnableToCheck' -Severity 'Medium' -Impact 'High' -Finding 'Unable to query required services.' -Recommendation 'Validate remote WMI/CIM permissions and service health.' -Evidence $_.Exception.Message -Source 'Win32_Service' -RuleId 'DP-SVC-000'
            }

            $shares = @()
            try {
                $shares = @(Get-CimInstance -CimSession $cim -ClassName Win32_Share -ErrorAction Stop)
                foreach($shareName in @('SMS_DP$','SCCMContentLib$')){
                    $share = $shares | Where-Object { $_.Name -eq $shareName } | Select-Object -First 1
                    if($share){
                        Add-DPResult -Category 'Content' -Check ("Share {0}" -f $shareName) -Target $server -Value ([string]$share.Path) -Status 'Healthy' -Finding "$shareName is available." -Recommendation 'No action required.' -Evidence ("Name={0}; Path={1}" -f $share.Name,$share.Path) -Source 'Win32_Share' -RuleId $(if($shareName -eq 'SMS_DP$'){'DP-CONTENT-001'}else{'DP-CONTENT-002'})
                    } else {
                        Add-DPResult -Category 'Content' -Check ("Share {0}" -f $shareName) -Target $server -Value 'Not found' -Status 'Critical' -Severity 'High' -Impact 'High' -Finding "$shareName was not found." -Recommendation 'Validate DP role installation, Content Library health and share creation. Review distmgr.log, smsdpprov.log and Windows sharing configuration.' -Evidence 'Win32_Share returned no matching share.' -Source 'Win32_Share' -RuleId $(if($shareName -eq 'SMS_DP$'){'DP-CONTENT-001'}else{'DP-CONTENT-002'})
                    }
                }

                $contentShare = $shares | Where-Object { $_.Name -eq 'SCCMContentLib$' } | Select-Object -First 1
                if($contentShare -and $contentShare.Path){
                    $contentPath = [string]$contentShare.Path
                    $drive = if($contentPath -match '^([A-Za-z]:)'){ $Matches[1] } else { $null }
                    Add-DPResult -Category 'Content' -Check 'Content Library Location' -Target $server -Value $contentPath -Status 'Info' -Finding 'Content Library location was discovered from the SCCMContentLib$ share.' -Recommendation 'Confirm the Content Library is located on the intended data volume and excluded from antivirus real-time scanning according to organizational policy.' -Evidence $contentPath -Source 'Win32_Share' -RuleId 'DP-CONTENT-003'
                    if($drive){
                        $disk = Get-CimInstance -CimSession $cim -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $drive) -ErrorAction Stop
                        if($disk -and [double]$disk.Size -gt 0){
                            $freeGB = [math]::Round(([double]$disk.FreeSpace/1GB),2)
                            $totalGB = [math]::Round(([double]$disk.Size/1GB),2)
                            $freePct = [math]::Round((([double]$disk.FreeSpace/[double]$disk.Size)*100),1)
                            $status='Healthy'; $severity='Info'; $impact='Low'; $recommendation='No action required.'
                            if($freePct -lt [double]$Session.Policy.DiskFree.CriticalBelowPercent -or $freeGB -lt [double]$Session.Policy.DiskFree.CriticalBelowGB){
                                $status='Critical'; $severity='High'; $impact='High'; $recommendation='Increase capacity or remove obsolete content. Validate package cleanup, orphaned content and Content Library health.'
                            } elseif($freePct -lt [double]$Session.Policy.DiskFree.HealthyMinPercent -or $freeGB -lt [double]$Session.Policy.DiskFree.WarningBelowGB){
                                $status='Warning'; $severity='Medium'; $impact='Medium'; $recommendation='Plan capacity expansion or content cleanup before distribution operations are affected.'
                            }
                            Add-DPResult -Category 'Storage' -Check ("Content Library Volume {0}" -f $drive) -Target $server -Value ("Free={0} GB; Total={1} GB; FreePct={2}%" -f $freeGB,$totalGB,$freePct) -Status $status -Severity $severity -Impact $impact -Finding ("Content Library volume has {0}% free space." -f $freePct) -Recommendation $recommendation -Evidence ("DeviceID={0}; FreeSpace={1}; Size={2}" -f $disk.DeviceID,$disk.FreeSpace,$disk.Size) -Source 'Win32_LogicalDisk' -RuleId 'DP-STORAGE-001'
                        }
                    }
                }
            } catch {
                Add-DPResult -Category 'Content' -Check 'DP Shares and Content Library' -Target $server -Status 'UnableToCheck' -Severity 'Medium' -Impact 'High' -Finding 'Unable to query DP shares or Content Library information.' -Recommendation 'Validate remote WMI/CIM permissions and the Server service.' -Evidence $_.Exception.Message -Source 'Win32_Share' -RuleId 'DP-CONTENT-000'
            }

            try {
                $fixedDisks = @(Get-CimInstance -CimSession $cim -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop)
                $markerResults = New-Object System.Collections.ArrayList
                foreach($disk in $fixedDisks){
                    $driveRoot = [string]$disk.DeviceID + '\'
                    $marker = $null
                    try {
                        $marker = Invoke-Command -ComputerName $server -ScriptBlock { param($p) Test-Path -LiteralPath (Join-Path $p 'NO_SMS_ON_DRIVE.SMS') } -ArgumentList $driveRoot -ErrorAction Stop
                    } catch { $marker = $null }
                    if($null -ne $marker){
                        [void]$markerResults.Add(("{0}={1}" -f $disk.DeviceID,$marker))
                    }
                }
                if($markerResults.Count -gt 0){
                    Add-DPResult -Category 'Storage' -Check 'NO_SMS_ON_DRIVE.SMS Markers' -Target $server -Value ($markerResults -join '; ') -Status 'Info' -Finding 'Drive exclusion markers were inspected.' -Recommendation 'Confirm markers exist only on volumes that must not host ConfigMgr content.' -Evidence ($markerResults -join '; ') -Source 'PowerShell Remoting' -RuleId 'DP-STORAGE-002'
                } else {
                    Add-DPResult -Category 'Storage' -Check 'NO_SMS_ON_DRIVE.SMS Markers' -Target $server -Value 'Not inspected' -Status 'UnableToCheck' -Severity 'Low' -Impact 'Low' -Finding 'Drive markers could not be inspected because PowerShell remoting was unavailable or denied.' -Recommendation 'Enable authorized PowerShell remoting for complete evidence collection, or inspect the marker files manually.' -Evidence 'No remote marker result was returned.' -Source 'PowerShell Remoting' -RuleId 'DP-STORAGE-002'
                }
            } catch {
                Add-DPResult -Category 'Storage' -Check 'NO_SMS_ON_DRIVE.SMS Markers' -Target $server -Status 'UnableToCheck' -Severity 'Low' -Impact 'Low' -Finding 'Drive exclusion markers could not be inspected.' -Recommendation 'Inspect NO_SMS_ON_DRIVE.SMS manually on fixed volumes.' -Evidence $_.Exception.Message -Source 'PowerShell Remoting' -RuleId 'DP-STORAGE-002'
            }

            Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
        }

        # Site-provider evidence that does not change the environment
        try {
            $siteCode = [string]$Session.Inventory.Site.SiteCode
            $provider = @($Session.Results | Where-Object { $_.Module -eq 'Discovery' -and $_.Check -eq 'SMS Provider' } | Select-Object -First 1 -ExpandProperty Target)
            if($provider.Count -gt 0 -and $siteCode){
                $namespace = "root\SMS\site_$siteCode"
                $escaped = $server.Replace("'","''")
                $dpInfo = @(Get-CimInstance -ComputerName $provider[0] -Namespace $namespace -ClassName SMS_DistributionPointInfo -Filter ("Name='{0}'" -f $escaped) -ErrorAction Stop | Select-Object -First 1)
                if($dpInfo.Count -gt 0){
                    $props = @('Name','SiteCode','IsPeerDP','IsPullDP','IsPXE','IsMulticast','IsProtected','IsPrestagingAllowed')
                    $evidence = @()
                    foreach($p in $props){ if($dpInfo[0].PSObject.Properties.Name -contains $p){ $evidence += ("{0}={1}" -f $p,$dpInfo[0].$p) } }
                    Add-DPResult -Category 'Configuration' -Check 'ConfigMgr DP Configuration' -Target $server -Value ($evidence -join '; ') -Status 'Info' -Finding 'Distribution Point configuration was read from the SMS Provider.' -Recommendation 'Review the flags against the intended DP design.' -Evidence ($evidence -join '; ') -Source 'SMS_DistributionPointInfo' -RuleId 'DP-CONFIG-001'
                } else {
                    Add-DPResult -Category 'Configuration' -Check 'ConfigMgr DP Configuration' -Target $server -Value 'No row returned' -Status 'Warning' -Severity 'Medium' -Impact 'Medium' -Finding 'The DP was discovered as a role, but SMS_DistributionPointInfo returned no matching row.' -Recommendation 'Validate the DP role state in the console and review distmgr.log.' -Evidence "Provider=$($provider[0]); Namespace=$namespace" -Source 'SMS_DistributionPointInfo' -RuleId 'DP-CONFIG-001'
                }
            }
        } catch {
            Add-DPResult -Category 'Configuration' -Check 'ConfigMgr DP Configuration' -Target $server -Status 'UnableToCheck' -Severity 'Low' -Impact 'Medium' -Finding 'Unable to read extended DP configuration from the SMS Provider.' -Recommendation 'Validate RBAC/WMI access. Core DP operating system checks remain valid.' -Evidence $_.Exception.Message -Source 'SMS_DistributionPointInfo' -RuleId 'DP-CONFIG-001'
        }

        $serverResults = @($Session.Results | Select-Object -Skip $startResultCount)
        $worst = Get-WorstStatusLocal -Items $serverResults
        [void]$serverSummaries.Add([pscustomobject]@{ Server=$server; Status=$worst; Results=$serverResults.Count })
        Send-Log ("Distribution Point completed: {0}; Status={1}; Results={2}" -f $server,$worst,$serverResults.Count)
    }

    Send-Progress 100 'Distribution Point assessment completed.'
    $sw.Stop()
    $summary = [pscustomobject]@{
        DistributionPoints = $dpServers.Count
        Healthy = @($serverSummaries | Where-Object Status -eq 'Healthy').Count
        Warning = @($serverSummaries | Where-Object Status -eq 'Warning').Count
        Critical = @($serverSummaries | Where-Object Status -eq 'Critical').Count
        UnableToCheck = @($serverSummaries | Where-Object Status -eq 'UnableToCheck').Count
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds,1)
    }
    $Session.Inventory.DistributionPointAssessment = $summary
    Send-Log ("Distribution Point assessment completed. DPs={0}; Warning={1}; Critical={2}; UnableToCheck={3}; Duration={4}s" -f $summary.DistributionPoints,$summary.Warning,$summary.Critical,$summary.UnableToCheck,$summary.DurationSeconds)
    return $summary
}
Export-ModuleMember -Function Invoke-CATDistributionPointAssessment
