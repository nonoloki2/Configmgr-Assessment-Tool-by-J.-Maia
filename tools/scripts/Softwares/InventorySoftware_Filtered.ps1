# List of target software names to match
$targetSoftware = @(
    "Google Chrome",
    "Microsoft Edge",
    "Microsoft Office",          # Covers MS Office / O365
    "Java SE Development Kit 24.0.2 (64-bit)",
    "Java SE Development Kit 8 Update 451 (32-bit)",
    "Java SE Development Kit 8 Update 451 (64-bit)",
    "WinSCP 6.5",
    "SoapUI 5.9.0"
)

# Function to retrieve installed software from registry
function Get-InstalledSoftware {
    $softwareList = @()

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

# Run inventory and filter by target software list
$installedSoftware = Get-InstalledSoftware

# Match installed software against target list (case-insensitive, partial match allowed)
$matchedSoftware = $installedSoftware | Where-Object {
    $name = $_.DisplayName
    $targetSoftware | Where-Object { $name -like "*$_*" }
}

# Display results
if ($matchedSoftware) {
    Write-Host "`n🎯 Matched Software Found:" -ForegroundColor Cyan
    $matchedSoftware | Sort-Object DisplayName | Format-Table -AutoSize
} else {
    Write-Host "`n⚠️ No target software found on this device." -ForegroundColor Yellow
}