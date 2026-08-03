#requires -version 5.1
<#
.SYNOPSIS
    Removes the packaged SAP GUI 7.50 build, installs SAP GUI 8.00 silently,
    and deploys SAP Logon landscape configuration to existing and future users.

.EXPECTED SOURCE FILES (same folder as this script)
    PSEG_SAP_750_ACN.exe              Optional, used to remove the old package
    PSEG_SAP_GUI_800_ACN.exe          Required, SAP GUI 8.00 installer
    SAPUILandscape.xml                Recommended
    SAPUILandscapeGlobal.xml          Recommended
    saplogon.ini                      Optional legacy configuration

.SCCM INSTALL COMMAND
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-SAPGUI80-MigrateConfig.ps1

.NOTES
    Designed to run as Local System from Microsoft Configuration Manager.
#>

[CmdletBinding()]
param(
    [string]$OldInstallerName = 'PSEG_SAP_750_ACN.exe',
    [string]$NewInstallerName = 'PSEG_SAP_GUI_800_ACN.exe',
    [switch]$SkipOldVersionRemoval
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogRoot   = Join-Path $env:ProgramData 'SAP\SAPGUI80-Migration\Logs'
$LogFile   = Join-Path $LogRoot ("SAPGUI80-Migration_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$MarkerDir = Join-Path $env:ProgramData 'SAP\SAPGUI80-Migration'
$Marker    = Join-Path $MarkerDir 'Installed.tag'

New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
New-Item -Path $MarkerDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Output $line
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Action
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "$Action file was not found: $FilePath"
    }

    Write-Log "$Action command: `"$FilePath`" $Arguments"
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $SourceDir -Wait -PassThru -WindowStyle Hidden
    Write-Log "$Action exit code: $($process.ExitCode)"

    if ($process.ExitCode -notin @(0, 1641, 3010)) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }

    return $process.ExitCode
}

function Stop-SapProcesses {
    $processNames = @('saplogon', 'saplgpad', 'sapshcut', 'nwbc')

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
        'Public', 'Default', 'Default User', 'All Users',
        'defaultuser0', 'WDAGUtilityAccount'
    )

    $paths = New-Object System.Collections.Generic.List[string]

    # Registry profiles are more reliable than blindly enumerating C:\Users.
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
            Write-Log "Could not inspect profile registry key $($key.PSChildName): $($_.Exception.Message)" 'WARN'
        }
    }

    # Also include the Default profile so future users receive the files.
    $defaultProfile = Join-Path $env:SystemDrive 'Users\Default'
    if (Test-Path -LiteralPath $defaultProfile -PathType Container) {
        [void]$paths.Add($defaultProfile)
    }

    return $paths | Sort-Object -Unique
}

function Copy-SapLandscapeConfiguration {
    $configFiles = @(
        'SAPUILandscape.xml',
        'SAPUILandscapeGlobal.xml',
        'saplogon.ini'
    )

    $available = foreach ($file in $configFiles) {
        $source = Join-Path $SourceDir $file

        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Get-Item -LiteralPath $source
        }
        else {
            Write-Log "Optional configuration file not found and will be skipped: $file" 'WARN'
        }
    }

    if (-not $available) {
        throw 'No SAP landscape configuration files were found beside the script.'
    }

    $backupStamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    foreach ($profilePath in Get-UserProfilePaths) {
        $destination = Join-Path $profilePath 'AppData\Roaming\SAP\Common'

        try {
            New-Item -Path $destination -ItemType Directory -Force | Out-Null

            foreach ($file in $available) {
                $target = Join-Path $destination $file.Name
                $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash

                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash

                    if ($sourceHash -eq $targetHash) {
                        Write-Log "Configuration already current; no replacement needed: $target"
                        continue
                    }

                    $backupName = '{0}.pre-SAPGUI80-{1}.bak' -f $file.Name, $backupStamp
                    $backupPath = Join-Path $destination $backupName

                    Copy-Item -LiteralPath $target -Destination $backupPath -Force
                    Write-Log "Existing configuration backed up: $target -> $backupPath"
                }

                Copy-Item -LiteralPath $file.FullName -Destination $target -Force

                $copiedHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                if ($copiedHash -ne $sourceHash) {
                    throw "Hash validation failed after copying '$($file.Name)' to '$destination'."
                }

                Write-Log "Configuration copied and validated: $($file.Name) -> $destination"
            }
        }
        catch {
            throw "Failed to deploy SAP configuration to profile '$profilePath': $($_.Exception.Message)"
        }
    }
}

$rebootRequired = $false

try {
    Write-Log '===== SAP GUI 7.50 to 8.00 migration started ====='
    Write-Log "Execution identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Log "Source directory: $SourceDir"

    Stop-SapProcesses

    if (-not $SkipOldVersionRemoval) {
        $oldInstaller = Join-Path $SourceDir $OldInstallerName
        if (Test-Path -LiteralPath $oldInstaller -PathType Leaf) {
            $exitCode = Invoke-Installer -FilePath $oldInstaller -Arguments '/silent /uninstall' -Action 'SAP GUI 7.50 uninstall'
            if ($exitCode -in @(1641, 3010)) { $rebootRequired = $true }
        }
        else {
            Write-Log "Old package installer not found; continuing with SAP GUI 8.00 installation: $oldInstaller" 'WARN'
        }
    }

    $newInstaller = Join-Path $SourceDir $NewInstallerName
    $exitCode = Invoke-Installer -FilePath $newInstaller -Arguments '/silent' -Action 'SAP GUI 8.00 install'
    if ($exitCode -in @(1641, 3010)) { $rebootRequired = $true }

    Copy-SapLandscapeConfiguration

    @(
        "InstalledUtc=$([DateTime]::UtcNow.ToString('o'))"
        "Installer=$NewInstallerName"
        "Configuration=SAPUILandscape.xml;SAPUILandscapeGlobal.xml;saplogon.ini"
    ) | Set-Content -Path $Marker -Encoding ASCII -Force

    Write-Log "Detection marker created: $Marker"
    Write-Log '===== SAP GUI migration completed successfully ====='

    if ($rebootRequired) {
        Write-Log 'A reboot was requested by one of the SAP installers.' 'WARN'
        exit 3010
    }

    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log "Migration failed. Review log: $LogFile" 'ERROR'
    exit 1
}
