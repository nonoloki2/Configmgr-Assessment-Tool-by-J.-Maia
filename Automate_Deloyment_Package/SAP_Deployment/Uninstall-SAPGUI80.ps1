#requires -version 5.1
<#
.SYNOPSIS
    Silently uninstalls the packaged SAP GUI 8.00 build deployed by SCCM.

.DESCRIPTION
    Designed to run as Local System from Microsoft Configuration Manager.
    By default, SAP landscape files under user profiles are preserved so a later
    reinstall or upgrade does not erase the user's configured SAP connections.

.EXPECTED SOURCE FILES
    PSEG_SAP_GUI_800_ACN.exe

.SCCM UNINSTALL COMMAND
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall-SAPGUI80.ps1

.OPTIONAL
    Use -RemoveUserConfiguration only when the SAP landscape files must also be deleted.
#>

[CmdletBinding()]
param(
    [string]$InstallerName = 'PSEG_SAP_GUI_800_ACN.exe',
    [switch]$RemoveUserConfiguration
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogRoot   = Join-Path $env:ProgramData 'SAP\SAPGUI80-Migration\Logs'
$LogFile   = Join-Path $LogRoot ("SAPGUI80-Uninstall_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$MarkerDir = Join-Path $env:ProgramData 'SAP\SAPGUI80-Migration'
$Marker    = Join-Path $MarkerDir 'Installed.tag'

New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Output $line
}

function Stop-SapProcesses {
    $processNames = @(
        'saplogon',
        'saplgpad',
        'sapshcut',
        'nwbc',
        'sapfewse'
    )

    foreach ($name in $processNames) {
        $running = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($running) {
            Write-Log "Stopping running SAP process: $name" 'WARN'
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-UserProfilePaths {
    $excludedNames = @(
        'Public',
        'Default User',
        'All Users',
        'defaultuser0',
        'WDAGUtilityAccount'
    )

    $paths = New-Object System.Collections.Generic.List[string]
    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    foreach ($key in Get-ChildItem -Path $profileList -ErrorAction SilentlyContinue) {
        try {
            $rawPath = (Get-ItemProperty -Path $key.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            $path = [Environment]::ExpandEnvironmentVariables($rawPath)
            $leaf = Split-Path -Leaf $path

            if ($path -like "$env:SystemRoot*") { continue }
            if ($excludedNames -contains $leaf) { continue }

            if (Test-Path -LiteralPath $path -PathType Container) {
                [void]$paths.Add($path)
            }
        }
        catch {
            Write-Log "Could not inspect profile key $($key.PSChildName): $($_.Exception.Message)" 'WARN'
        }
    }

    $defaultProfile = Join-Path $env:SystemDrive 'Users\Default'
    if (Test-Path -LiteralPath $defaultProfile -PathType Container) {
        [void]$paths.Add($defaultProfile)
    }

    return $paths | Sort-Object -Unique
}

function Remove-SapLandscapeConfiguration {
    $configurationFiles = @(
        'SAPUILandscape.xml',
        'SAPUILandscapeGlobal.xml',
        'saplogon.ini'
    )

    foreach ($profilePath in Get-UserProfilePaths) {
        $commonPath = Join-Path $profilePath 'AppData\Roaming\SAP\Common'

        foreach ($fileName in $configurationFiles) {
            $target = Join-Path $commonPath $fileName

            if (Test-Path -LiteralPath $target -PathType Leaf) {
                try {
                    Remove-Item -LiteralPath $target -Force
                    Write-Log "Removed configuration file: $target"
                }
                catch {
                    Write-Log "Could not remove configuration file '$target': $($_.Exception.Message)" 'WARN'
                }
            }
        }

        try {
            if ((Test-Path -LiteralPath $commonPath -PathType Container) -and
                -not (Get-ChildItem -LiteralPath $commonPath -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $commonPath -Force
                Write-Log "Removed empty directory: $commonPath"
            }
        }
        catch {
            Write-Log "Could not remove empty directory '$commonPath': $($_.Exception.Message)" 'WARN'
        }
    }
}

try {
    Write-Log '===== SAP GUI 8.00 uninstall started ====='
    Write-Log "Execution identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Source directory: $SourceDir"

    Stop-SapProcesses

    $installerPath = Join-Path $SourceDir $InstallerName

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "SAP GUI 8.00 installer was not found: $installerPath"
    }

    Write-Log "Uninstall command: `"$installerPath`" /silent /uninstall"

    $process = Start-Process `
        -FilePath $installerPath `
        -ArgumentList '/silent /uninstall' `
        -WorkingDirectory $SourceDir `
        -Wait `
        -PassThru `
        -WindowStyle Hidden

    Write-Log "Uninstall exit code: $($process.ExitCode)"

    if ($process.ExitCode -notin @(0, 1605, 1614, 1641, 3010)) {
        throw "SAP GUI 8.00 uninstall failed with exit code $($process.ExitCode)."
    }

    if ($RemoveUserConfiguration) {
        Write-Log 'User SAP landscape configuration removal was requested.' 'WARN'
        Remove-SapLandscapeConfiguration
    }
    else {
        Write-Log 'User SAP landscape configuration was preserved.'
    }

    if (Test-Path -LiteralPath $Marker -PathType Leaf) {
        Remove-Item -LiteralPath $Marker -Force
        Write-Log "Removed SCCM detection marker: $Marker"
    }

    Write-Log '===== SAP GUI 8.00 uninstall completed successfully ====='

    if ($process.ExitCode -in @(1641, 3010)) {
        Write-Log 'A reboot was requested by the SAP uninstaller.' 'WARN'
        exit 3010
    }

    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log "Uninstall failed. Review log: $LogFile" 'ERROR'
    exit 1
}
