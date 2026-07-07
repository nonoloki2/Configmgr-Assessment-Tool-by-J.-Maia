function Invoke-CATRule {
    [CmdletBinding()]
    param([string]$RuleId,[hashtable]$Data)
    switch ($RuleId) {
        'Connection.Success' { return @{ Status='Healthy'; Severity='Info'; Recommendation='No action required.' } }
        'Connection.Failed' { return @{ Status='Critical'; Severity='High'; Recommendation='Validate DNS, firewall, permissions and SMS Provider availability.' } }
        default { return @{ Status='Info'; Severity='Info'; Recommendation='' } }
    }
}
Export-ModuleMember -Function *
