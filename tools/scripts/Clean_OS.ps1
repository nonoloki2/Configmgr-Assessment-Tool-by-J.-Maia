# Check if the script is running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "This script must be run as Administrator."
    exit
}

# Start execution log
$logPath = "C:\Logs\Cleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
Start-Transcript -Path $logPath

Write-Host "Starting cleanup process..."

# Stop Windows Update service
Write-Host "Stopping Windows Update service..."
Stop-Service -Name wuauserv -Force

# Stop SCCM Client service
Write-Host "Stopping SCCM Client service..."
Stop-Service -Name CcmExec -Force

# Clean user temporary files
Write-Host "Cleaning user temporary files..."
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clean system temporary files
Write-Host "Cleaning system temporary files..."
Remove-Item "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clean Windows Update cache
Write-Host "Cleaning Windows Update cache..."
Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clean system logs
Write-Host "Cleaning system logs..."
Remove-Item "C:\Windows\Logs\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clean Microsoft Edge browser cache (if exists)
$edgeCache = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
if (Test-Path $edgeCache) {
    Write-Host "Cleaning Microsoft Edge browser cache..."
    Remove-Item "$edgeCache\*" -Recurse -Force -ErrorAction SilentlyContinue
}

# Clean SCCM cache folder
Write-Host "Cleaning SCCM cache folder..."
Remove-Item "C:\Windows\ccmcache\*" -Recurse -Force -ErrorAction SilentlyContinue

# Restart Windows Update service
Write-Host "Restarting Windows Update service..."
Start-Service -Name wuauserv

# Restart SCCM Client service
Write-Host "Restarting SCCM Client service..."
Start-Service -Name CcmExec

Write-Host "Cleanup completed successfully."

# End execution log
Stop-Transcript