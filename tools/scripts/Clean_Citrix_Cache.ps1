# Script: Clear-CitrixCache.ps1
# Purpose: Clear Citrix Workspace App cache to resolve connection/startup issues

$ErrorActionPreference = 'SilentlyContinue'

# Citrix cache folders
$paths = @(
    "$env:AppData\Local\Citrix\ICA Client",
    "$env:AppData\Roaming\Citrix\SelfService"
)

foreach ($path in $paths) {
    if (Test-Path $path) {
        Write-Output "Clearing cache at: $path"
        Remove-Item -Path $path -Recurse -Force
    } else {
        Write-Output "Folder not found: $path"
    }
}

Write-Output "✅ Cache cleanup completed. Please restart Citrix Workspace App and try again."
exit 0
