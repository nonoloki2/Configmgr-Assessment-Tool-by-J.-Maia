function Get-CATRuleDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][hashtable]$Data,
        [Parameter(Mandatory)][object]$Policy
    )

    switch ($RuleId) {
        'CORE-UPTIME-001' {
            $days = [double]$Data.Days
            if ($days -ge [double]$Policy.Uptime.CriticalMinDays) {
                return @{ Status='Critical'; Severity='High'; Impact='High'; Recommendation='Investigate patch compliance immediately. Verify latest cumulative updates, pending reboot state, and maintenance schedule.' }
            }
            elseif ($days -gt [double]$Policy.Uptime.HealthyMaxDays) {
                return @{ Status='Warning'; Severity='Medium'; Impact='Medium'; Recommendation='Verify Windows Update compliance and confirm whether a reboot is pending after the latest monthly cumulative update.' }
            }
            else {
                return @{ Status='Healthy'; Severity='Info'; Impact='Low'; Recommendation='No action required.' }
            }
        }
        'CORE-DISK-001' {
            $freePct = [double]$Data.FreePct
            $freeGB = [double]$Data.FreeGB
            if ($freePct -lt [double]$Policy.DiskFree.CriticalBelowPercent -or $freeGB -lt [double]$Policy.DiskFree.CriticalBelowGB) {
                return @{ Status='Critical'; Severity='High'; Impact='High'; Recommendation='Free disk space is critically low. Increase capacity or perform cleanup. Validate ConfigMgr logs, content library, WSUS/SUSDB, SQL files, IIS logs and cleanup strategy.' }
            }
            elseif ($freePct -lt [double]$Policy.DiskFree.HealthyMinPercent -or $freeGB -lt [double]$Policy.DiskFree.WarningBelowGB) {
                return @{ Status='Warning'; Severity='Medium'; Impact='Medium'; Recommendation='Free disk space is below recommended threshold. Plan cleanup or capacity expansion.' }
            }
            else {
                return @{ Status='Healthy'; Severity='Info'; Impact='Low'; Recommendation='No action required.' }
            }
        }
        'CORE-MEMORY-001' {
            $usedPct = [double]$Data.UsedPct
            if ($usedPct -ge [double]$Policy.MemoryUsage.CriticalAbovePercent) {
                return @{ Status='Critical'; Severity='High'; Impact='High'; Recommendation='Memory usage is critically high. Review processes, ConfigMgr/SQL/WSUS workload, and consider increasing RAM.' }
            }
            elseif ($usedPct -gt [double]$Policy.MemoryUsage.HealthyMaxPercent) {
                return @{ Status='Warning'; Severity='Medium'; Impact='Medium'; Recommendation='Memory usage is high. Review running processes and workload trends.' }
            }
            else {
                return @{ Status='Healthy'; Severity='Info'; Impact='Low'; Recommendation='No action required.' }
            }
        }
        'CORE-CPU-001' {
            $usedPct = [double]$Data.UsedPct
            if ($usedPct -ge [double]$Policy.CpuUsage.CriticalAbovePercent) {
                return @{ Status='Critical'; Severity='High'; Impact='High'; Recommendation='CPU usage is critically high. Review processes and role-specific workload.' }
            }
            elseif ($usedPct -gt [double]$Policy.CpuUsage.HealthyMaxPercent) {
                return @{ Status='Warning'; Severity='Medium'; Impact='Medium'; Recommendation='CPU usage is high. Review process activity and recurring maintenance windows.' }
            }
            else {
                return @{ Status='Healthy'; Severity='Info'; Impact='Low'; Recommendation='No action required.' }
            }
        }
        'CORE-PING-001' {
            $avg = [double]$Data.AverageMs
            $loss = [double]$Data.LossPct
            if ($loss -ge 100) {
                return @{ Status='Warning'; Severity='Low'; Impact='Medium'; Recommendation='Ping failed or ICMP is blocked. Validate network path; continue with WinRM/CIM before declaring the server unavailable.' }
            }
            elseif ($avg -ge [double]$Policy.Ping.CriticalLatencyMs) {
                return @{ Status='Critical'; Severity='High'; Impact='High'; Recommendation='Network latency is very high. Validate routing, WAN links, firewall inspection and server responsiveness.' }
            }
            elseif ($avg -ge [double]$Policy.Ping.WarningLatencyMs) {
                return @{ Status='Warning'; Severity='Medium'; Impact='Medium'; Recommendation='Network latency is above normal threshold. Validate network path and remote site performance.' }
            }
            else {
                return @{ Status='Healthy'; Severity='Info'; Impact='Low'; Recommendation='No action required.' }
            }
        }
        default { return @{ Status='Info'; Severity='Info'; Impact='Low'; Recommendation='' } }
    }
}

# Backward-compatible wrapper kept for older modules.
function Invoke-CATRule {
    [CmdletBinding()]
    param([string]$RuleId,[hashtable]$Data,[object]$Policy)
    if ($Policy) { return Get-CATRuleDecision -RuleId $RuleId -Data $Data -Policy $Policy }
    switch ($RuleId) {
        'Connection.Success' { return @{ Status='Healthy'; Severity='Info'; Impact='Low'; Recommendation='No action required.' } }
        'Connection.Failed' { return @{ Status='Critical'; Severity='High'; Impact='High'; Recommendation='Validate DNS, firewall, permissions and SMS Provider availability.' } }
        default { return @{ Status='Info'; Severity='Info'; Impact='Low'; Recommendation='' } }
    }
}
Export-ModuleMember -Function *
