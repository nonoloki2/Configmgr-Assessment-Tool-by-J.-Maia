function Invoke-CATDiscovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SiteCode,
        [Parameter(Mandatory)][string]$ProviderServer,
        [Parameter(Mandatory)][string]$AssessmentId,
        [scriptblock]$Logger
    )

    $results = New-Object System.Collections.Generic.List[object]
    $namespace = "root\SMS\site_$SiteCode"

    function Add-ResultLocal {
        param($obj)
        [void]$results.Add($obj)
    }

    & $Logger "Validating input fields..." 'INFO'
    if ([string]::IsNullOrWhiteSpace($SiteCode)) {
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Input Validation' -CheckName 'Site Code' -Status 'Critical' -Severity 'Critical' -Finding 'Site Code is empty.' -Recommendation 'Inform the ConfigMgr Site Code before running discovery.' -Evidence 'Empty input')
        return $results
    }
    Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Input Validation' -CheckName 'Site Code' -Status 'Healthy' -Severity 'None' -Finding 'Site Code was provided.' -Recommendation 'No action required.' -Evidence $SiteCode)

    if ([string]::IsNullOrWhiteSpace($ProviderServer)) {
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Input Validation' -CheckName 'SMS Provider' -Status 'Critical' -Severity 'Critical' -Finding 'SMS Provider is empty.' -Recommendation 'Inform the SMS Provider server before running discovery.' -Evidence 'Empty input')
        return $results
    }
    Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Input Validation' -CheckName 'SMS Provider' -Status 'Healthy' -Severity 'None' -Finding 'SMS Provider was provided.' -Recommendation 'No action required.' -Evidence $ProviderServer)

    & $Logger "Testing ping to $ProviderServer..." 'INFO'
    try {
        $pingOk = Test-Connection -ComputerName $ProviderServer -Count 1 -Quiet -ErrorAction Stop
        if ($pingOk) {
            Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Connectivity' -CheckName 'Ping' -Status 'Healthy' -Severity 'None' -Finding 'Provider server responded to ICMP ping.' -Recommendation 'No action required.' -Evidence 'Test-Connection returned True')
            & $Logger "Ping OK." 'SUCCESS'
        } else {
            Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Connectivity' -CheckName 'Ping' -Status 'Warning' -Severity 'Medium' -Finding 'Provider server did not respond to ICMP ping.' -Recommendation 'Validate firewall/ICMP policy. Continue if WMI connection works.' -Evidence 'Test-Connection returned False')
            & $Logger "Ping failed or ICMP blocked." 'WARN'
        }
    } catch {
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Connectivity' -CheckName 'Ping' -Status 'UnableToCheck' -Severity 'Medium' -Finding 'Unable to test ping.' -Recommendation 'Validate network access and DNS resolution.' -Evidence $_.Exception.Message)
        & $Logger "Ping check error: $($_.Exception.Message)" 'ERROR'
    }

    & $Logger "Testing WinRM to $ProviderServer..." 'INFO'
    try {
        $null = Test-WSMan -ComputerName $ProviderServer -ErrorAction Stop
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Connectivity' -CheckName 'WinRM' -Status 'Healthy' -Severity 'None' -Finding 'WinRM responded successfully.' -Recommendation 'No action required.' -Evidence 'Test-WSMan succeeded')
        & $Logger "WinRM OK." 'SUCCESS'
    } catch {
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Connectivity' -CheckName 'WinRM' -Status 'Warning' -Severity 'Medium' -Finding 'WinRM did not respond.' -Recommendation 'Enable/validate WinRM if future remote server checks are needed. Discovery may still work through WMI/DCOM.' -Evidence $_.Exception.Message)
        & $Logger "WinRM warning: $($_.Exception.Message)" 'WARN'
    }

    & $Logger "Connecting to SMS Provider namespace $namespace on $ProviderServer..." 'INFO'
    try {
        $site = Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace -ClassName SMS_Site -ErrorAction Stop | Select-Object -First 1
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'SMS Provider' -CheckName 'Provider Namespace Connection' -Status 'Healthy' -Severity 'None' -Finding 'Successfully connected to SMS Provider namespace.' -Recommendation 'No action required.' -Evidence $namespace)
        & $Logger "SMS Provider connection OK." 'SUCCESS'

        if ($site) {
            $evidence = "SiteName=$($site.SiteName); Version=$($site.Version); Build=$($site.BuildNumber); Type=$($site.Type)"
            Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Site Information' -CheckName 'ConfigMgr Site Information' -Status 'Info' -Severity 'None' -Finding 'ConfigMgr site information collected.' -Recommendation 'Review collected metadata.' -Evidence $evidence)
            & $Logger "Site information: $evidence" 'INFO'
        }
    } catch {
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'SMS Provider' -CheckName 'Provider Namespace Connection' -Status 'Critical' -Severity 'Critical' -Finding 'Unable to connect to SMS Provider namespace.' -Recommendation 'Validate Site Code, SMS Provider server, permissions, firewall, WMI/CIM access and that the SMS Provider role is installed.' -Evidence $_.Exception.Message)
        & $Logger "SMS Provider connection failed: $($_.Exception.Message)" 'ERROR'
        return $results
    }

    & $Logger "Reading site system roles..." 'INFO'
    try {
        $roles = Get-CimInstance -ComputerName $ProviderServer -Namespace $namespace -ClassName SMS_SystemResourceList -ErrorAction Stop |
            Select-Object ServerName, SiteCode, RoleName, NALPath

        $serverCount = ($roles | Select-Object -ExpandProperty ServerName -Unique | Measure-Object).Count
        $roleCount = ($roles | Measure-Object).Count
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Site Systems' -CheckName 'Roles Inventory' -Status 'Healthy' -Severity 'None' -Finding "Discovered $roleCount role assignments across $serverCount server(s)." -Recommendation 'No action required.' -Evidence "Roles=$roleCount; Servers=$serverCount")
        & $Logger "Roles discovered: $roleCount. Servers discovered: $serverCount." 'SUCCESS'

        foreach ($role in $roles) {
            Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $role.ServerName -Role $role.RoleName -Module 'Discovery' -Category 'Site Systems' -CheckName 'Discovered Role' -Status 'Info' -Severity 'None' -Finding "Role discovered on site system server." -Recommendation 'Review role inventory.' -Evidence "Role=$($role.RoleName); Server=$($role.ServerName); NALPath=$($role.NALPath)")
        }
    } catch {
        Add-ResultLocal (New-AssessmentResult -AssessmentId $AssessmentId -SiteCode $SiteCode -ProviderServer $ProviderServer -TargetServer $ProviderServer -Module 'Discovery' -Category 'Site Systems' -CheckName 'Roles Inventory' -Status 'UnableToCheck' -Severity 'High' -Finding 'Unable to read site system roles.' -Recommendation 'Validate permissions to SMS_SystemResourceList and SMS Provider health.' -Evidence $_.Exception.Message)
        & $Logger "Role inventory failed: $($_.Exception.Message)" 'ERROR'
    }

    & $Logger "Discovery completed." 'SUCCESS'
    return $results
}

Export-ModuleMember -Function Invoke-CATDiscovery
