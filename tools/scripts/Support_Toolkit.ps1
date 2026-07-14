#requires -RunAsAdministrator
<#
IT-Toolkit.ps1
Terminal maintenance menu - Clean Disk, Reset WU, Reinstall SCCM CCM Agent, WMI repair/reset + extras.
All prompts/messages in English.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==========================
# Helpers
# ==========================
$Global:LogPath = Join-Path $env:TEMP ("IT-Toolkit_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","OK")][string]$Level="INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -Path $Global:LogPath -Value $line
}

function Pause-Console { Read-Host "Press ENTER to continue..." | Out-Null }

function Test-IsAdmin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Host "Please run this script as Administrator." -ForegroundColor Red
        exit 1
    }
}

function Get-FolderSizeBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            Measure-Object -Property Length -Sum).Sum
        return [int64]($sum ?? 0)
    } catch { return 0 }
}

function Clear-FolderContents {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
        }
        Write-Log "Cleared contents: $Path" "OK"
    } catch {
        Write-Log "Failed to clear $Path : $($_.Exception.Message)" "WARN"
    }
}

# ==========================
# 1) Clean Disk
# ==========================
function Invoke-CleanDisk {
    Write-Log "==== CLEAN DISK started ===="
    Clear-FolderContents -Path $env:TEMP
    Clear-FolderContents -Path "C:\Windows\Temp"
    Write-Log "==== CLEAN DISK finished ===="
}

# ==========================
# 2) Reset Windows Update Components
# ==========================
function Invoke-ResetWindowsUpdate {
    Write-Log "==== RESET WINDOWS UPDATE COMPONENTS started ===="

    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service bits -Force -ErrorAction SilentlyContinue

    Rename-Item "C:\Windows\SoftwareDistribution" "SoftwareDistribution.old" -ErrorAction SilentlyContinue
    Rename-Item "C:\Windows\System32\catroot2" "catroot2.old" -ErrorAction SilentlyContinue

    Start-Service wuauserv -ErrorAction SilentlyContinue
    Start-Service bits -ErrorAction SilentlyContinue

    Write-Log "==== RESET WINDOWS UPDATE COMPONENTS finished ====" "OK"
}

# ==========================
# 3) Reinstall CCM Agent
# ==========================
function Invoke-ReinstallCCMAgent {
    Write-Log "==== REINSTALL CCM AGENT started ===="

    $ccmsetup = "C:\Windows\CCMSetup\ccmsetup.exe"
    $site  = Read-Host "Enter SMSSITECODE (example: PR1)"
    $smsmp = Read-Host "Enter SMSMP (example: https://server.company.com)"

    if (-not (Test-Path $ccmsetup)) {
        Write-Log "ccmsetup.exe not found." "ERROR"
        return
    }

    $args = @("/forceinstall")
    if ($site)  { $args += "SMSSITECODE=$site" }
    if ($smsmp) { $args += "SMSMP=$smsmp" }

    & $ccmsetup @args
    Write-Log "==== REINSTALL CCM AGENT finished ====" "OK"
}

# ==========================
# 4) Rebuild WMI
# ==========================
function Invoke-RebuildWMIRepository {
    Write-Log "Running winmgmt /salvagerepository"
    winmgmt /salvagerepository
    Write-Log "Rebuild WMI completed." "OK"
}

# ==========================
# 5) Reset WMI
# ==========================
function Invoke-ResetWMIRepository {
    Write-Log "Running winmgmt /resetrepository"
    winmgmt /resetrepository
    Write-Log "Reset WMI completed." "OK"
}

# ==========================
# 6) DISM
# ==========================
function Invoke-DISMRestoreHealth {
    dism /Online /Cleanup-Image /RestoreHealth
}

# ==========================
# 7) SFC
# ==========================
function Invoke-SFCScanNow {
    sfc /scannow
}

# ==========================
# 8) Disk Free Space
# ==========================
function Invoke-GetDiskFreeSpace {
    Get-PSDrive -PSProvider 'FileSystem' |
    Select-Object Name,
    @{Name="FreeSpace(GB)";Expression={[math]::round($_.Free/1GB,2)}},
    @{Name="UsedSpace(GB)";Expression={[math]::round($_.Used/1GB,2)}},
    @{Name="TotalSize(GB)";Expression={[math]::round($_.Used/1GB + $_.Free/1GB,2)}} |
    Format-Table -AutoSize
}

# ==========================
# 9) Clear CCMCache
# ==========================
function Invoke-ClearCCMCache {
    Clear-FolderContents -Path "C:\Windows\ccmcache"
}

# ==========================
# 10) Get Installed Software
# ==========================
function Invoke-GetInstalledSoftware {
    Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                     HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
    Where-Object { $_.DisplayName -ne $null } |
    Sort-Object DisplayName |
    Format-Table -AutoSize
}

# ==========================
# 11) Reset CCM Policies
# ==========================
function Invoke-ResetCCMPolicies {
    Write-Log "==== RESET CCM POLICIES started ===="

    try {
        Invoke-WMIMethod -Namespace root\ccm -Class SMS_Client -Name ResetPolicy -ArgumentList "1"
        Write-Log "CCM policies reset successfully." "OK"
    }
    catch {
        Write-Log "Failed to reset CCM policies: $($_.Exception.Message)" "ERROR"
    }

    Write-Log "==== RESET CCM POLICIES finished ===="
}

# ==========================
# Menu
# ==========================
function Show-Menu {
    Clear-Host
    Write-Host "==============================="
    Write-Host "    JM IT Toolkit (PowerShell)   "
    Write-Host "==============================="
    Write-Host ""
    Write-Host "1  - Clean Disk"
    Write-Host "2  - Reset Windows Update Components"
    Write-Host "3  - Reinstall CCM Agent"
    Write-Host "4  - Rebuild WMI Repository"
    Write-Host "5  - Reset WMI Repository"
    Write-Host "6  - DISM RestoreHealth"
    Write-Host "7  - SFC Scannow"
    Write-Host "8  - Get Disk Free Space"
    Write-Host "9  - Clear CCMCache Folder"
    Write-Host "10 - Get Installed Software"
    Write-Host "11 - Reset CCM Policies"
    Write-Host "0  - Exit"
    Write-Host ""
}

# ==========================
# Main
# ==========================
Ensure-Admin

:MainLoop while ($true) {
    Show-Menu
    $opt = (Read-Host "Select an option").Trim()

    switch ($opt) {
        "1"  { Invoke-CleanDisk; Pause-Console }
        "2"  { Invoke-ResetWindowsUpdate; Pause-Console }
        "3"  { Invoke-ReinstallCCMAgent; Pause-Console }
        "4"  { Invoke-RebuildWMIRepository; Pause-Console }
        "5"  { Invoke-ResetWMIRepository; Pause-Console }
        "6"  { Invoke-DISMRestoreHealth; Pause-Console }
        "7"  { Invoke-SFCScanNow; Pause-Console }
        "8"  { Invoke-GetDiskFreeSpace; Pause-Console }
        "9"  { Invoke-ClearCCMCache; Pause-Console }
        "10" { Invoke-GetInstalledSoftware; Pause-Console }
        "11" { Invoke-ResetCCMPolicies; Pause-Console }
        "0"  { Write-Log "Exiting..."; break MainLoop }
        default { Write-Host "Invalid option."; Start-Sleep 1 }
    }
}