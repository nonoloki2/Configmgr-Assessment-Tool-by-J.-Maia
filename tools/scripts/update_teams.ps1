$pkg = "MSTeams_8wekyb3d8bbwe"
$path = "C:\Install\MSTeams-x64.msix"

# For each user who already has the package installed, update it silently
Get-AppxPackage -AllUsers -Name MSTeams | ForEach-Object {
    Write-Host "Updating Teams for user: $($_.PackageUserInformation.UserSecurityId)"
    Add-AppxPackage -Path $path -ForceApplicationShutdown -ForceUpdateFromAnyVersion -ErrorAction SilentlyContinue
}
