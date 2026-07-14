# Function to retrieve installed software from registry
function Get-InstalledSoftware {
    $softwareList = @()

    # Registry paths for installed software (64-bit, 32-bit, and current user)
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $registryPaths) {
        try {
            $softwareList += Get-ItemProperty $path | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
        } catch {
            Write-Warning "Failed to access $path"
        }
    }

    # Filter out entries without a DisplayName
    $softwareList = $softwareList | Where-Object { $_.DisplayName -ne $null }

    return $softwareList
}

# Run the function and display results in a formatted table
$installedSoftware = Get-InstalledSoftware
$installedSoftware | Sort-Object DisplayName | Format-Table -AutoSize