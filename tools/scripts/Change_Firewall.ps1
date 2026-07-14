# Remove MDM Firewall keys (SharedAccess) + WindowsFirewall policy key
# Exit codes: 0 = success (may require reboot), 1 = error

$ErrorActionPreference = "Stop"

$keysToDelete = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\Mdm",
    "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall"
)

$deletedAny = $false

try {
    foreach ($k in $keysToDelete) {
        if (Test-Path $k) {
            Remove-Item -Path $k -Recurse -Force
            Write-Output "Deleted key: $k"
            $deletedAny = $true
        }
        else {
            Write-Output "Key not found (skipped): $k"
        }
    }

    if ($deletedAny) {
        # Flag that a reboot is required (common pattern used by management tools)
        $rebootFlag = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
        if (-not (Test-Path $rebootFlag)) {
            New-Item -Path $rebootFlag -Force | Out-Null
        }
        Write-Output "Changes applied. Reboot is required."
    }
    else {
        Write-Output "Nothing to delete. No changes made."
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}
