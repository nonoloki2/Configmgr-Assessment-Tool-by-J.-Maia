[CmdletBinding()]
PARAM (
	[Parameter(Mandatory=$false)]
	[switch]$Uninstall = $false,
	[Parameter(Mandatory=$false)]
	[switch]$AllowRebootPassThru = $false
)

# // SCRIPT VARIABLES
[string]$ScriptPath 		= $MyInvocation.MyCommand.Definition
[string]$ScriptRoot 		= Split-Path -Path $ScriptPath -Parent
[string]$ScriptSeparator 	= '*' * 59
[string]$envComputerName 	= $env:ComputerName
[string]$envSystemRoot 		= $env:SystemRoot
[string]$envProgramData 	= $env:ProgramData
[string]$envProgramFiles 	= $env:ProgramFiles
[string]$envProgramFilesX86	= ${env:ProgramFiles(x86)}
[string]$AppVendor			= "SAP"
[string]$AppName			= "SAP Frontend 8.00 V18"
[string]$AppVersion			= "v18 (03.04.2025)"
[string]$LogsDir 			= "$envSystemRoot\Logs"
[string]$Author 			= "Bagati"
[string]$LogFile 			= "$LogsDir\$($AppVendor -replace ' ', '')_$($AppName -replace ' ', '')_$($AppVersion -replace ' ', '')_{0}.log"
[psobject]$OS				= Get-WmiObject -Class 'Win32_OperatingSystem' | Select-Object 'Caption','Version','OSArchitecture'
If ([string]::IsNullOrEmpty($envProgramFilesX86)) { $envProgramFilesX86 = $envProgramFiles }
If ($Uninstall) { $LogFile = $LogFile -f 'Uninstall' } Else { $LogFile = $LogFile -f 'Install' }
[int32]$ExitCode = 0
# // SCRIPT VARIABLES

# // FUNCTIONS
Function Test-IsAdmin {
    [CmdletBinding()]
    [OutputType([Bool])]
    PARAM ( )
    Try {
		$Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
		$Principal = New-Object System.Security.Principal.WindowsPrincipal($Identity)
		$Admin = [System.Security.Principal.WindowsBuiltInRole]::Administrator
		Return ($Principal.IsInRole($Admin))
	} Catch { Return $false }
}

Function Write-Log {
    [CmdletBinding()]
    PARAM (
		[Parameter(Mandatory=$true)]
		[ValidateNotNullOrEmpty()]
		[string]$File,
		[Parameter(Mandatory=$false)]
		[AllowEmptyCollection()]
        [string[]]$Message = ''
	)
	[string]$timeStamp = (Get-Date -f 'yyyy-MM-dd  HH:mm:ss').ToString()
	If (-not(Test-Path -Path $File)) { $null = New-Item $File -Force -ItemType 'File' }
	"[$timeStamp]  $Message" | Out-File -FilePath $File -Append
}

Function Exit-Script {
	[CmdletBinding()]
	PARAM (
		[Parameter(Mandatory = $false)]
		[ValidateNotNullorEmpty()]
		[int32]$ExitCode = 0
	)
	Write-Log $LogFile "Script will now exit with [$ExitCode] return code."
	Write-Log $LogFile "*** End [$AppName $AppVersion] Script ***"
	Write-Log $LogFile $ScriptSeparator
	If (Test-Path -LiteralPath 'variable:HostInvocation') { $script:ExitCode = $ExitCode; Exit } Else { Exit $ExitCode }
}

Function Delete-HKCURegFromAllProfiles {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory=$true)]
		[ValidateNotNullorEmpty()]
		[string]$Key,
		[Parameter(Mandatory=$false)]
		[string]$Name
	)
	$PatternSID = 'S-1-5-21-\d+-\d+\-\d+\-\d+$'
	$ProfileList = @(
		Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" |
		Where-Object {$_.PSChildName -match $PatternSID} |
		Select  @{name="SID";expression={$_.PSChildName}},
				@{name="UserHive";expression={"$($_.ProfileImagePath)\ntuser.dat"}},
				@{name="Username";expression={$_.ProfileImagePath -replace '^(.*[\\\/])', ''}}
	)
	$LoadedHives = Get-ChildItem "Registry::HKEY_USERS" | Where-Object {$_.PSChildname -match $PatternSID} | Select @{name="SID";expression={$_.PSChildName}}
	$UnloadedHives = Compare-Object $ProfileList.SID $LoadedHives.SID | Select @{name="SID";expression={$_.InputObject}}, UserHive, Username

	Foreach ($item in $ProfileList) {
		If ($item.SID -in $UnloadedHives.SID) { REG LOAD HKU\$($Item.SID) $($Item.UserHive) | Out-Null }

		If ([string]::IsNullOrEmpty($Name)) {
			$null = Remove-Item "Registry::HKEY_USERS\$($Item.SID)\$Key" -Recurse -Force -Confirm:$false -ErrorAction 'SilentlyContinue'
		}
		Else {
			If ((Get-ItemProperty -Path "Registry::HKEY_USERS\$($Item.SID)\$Key" -Name $Name -ErrorAction 'SilentlyContinue') -ne $null) {
				Write-Log $LogFile "Deleting registry key [HKEY_USERS\$($Item.SID)\$Key] value [$Name]..."
				$null = Remove-ItemProperty "Registry::HKEY_USERS\$($Item.SID)\$Key" $Name -Force -Confirm:$false -ErrorAction 'SilentlyContinue'
			}
		}

		If ($item.SID -in $UnloadedHives.SID) {
			[gc]::Collect()
			REG UNLOAD HKU\$($Item.SID) | Out-Null
		}
	}
}

Function Ensure-Dir {
	[CmdletBinding()]
	Param(
		[Parameter(Mandatory=$true)]
		[string]$Path
	)
	if (-not (Test-Path -Path $Path -PathType Container)) {
		$null = New-Item -Path $Path -ItemType Directory -Force
	}
}

# // FUNCTIONS

#	//		START EXECUTION		//	#
Write-Log $LogFile "*** Begin [$AppName $AppVersion] Script ***"
Write-Log $LogFile $ScriptSeparator
Write-Log $LogFile "Computer Name: [$($envComputerName.ToUpper())]"
Write-Log $LogFile "Detected O.S: [$($OS.Caption) v$($OS.Version)]"
Write-Log $LogFile "Uninstall only ? [$($Uninstall.ToString().ToUpper())]"
Write-Log $LogFile "Exit with restart exit code, if required ? [$($AllowRebootPassThru.ToString().ToUpper())]"

If (-not(Test-IsAdmin)) {
	Write-Log $LogFile "Administrator privileges are required to run this script.  Please re-launch script with administrator privileges."
	Exit-Script -ExitCode 30001
}
Write-Log $LogFile "User/executor has Admin privileges."

[string]$SAPDir = "$envProgramFilesX86\SAP"
[boolean]$RestartFlagRaised = $false

If ($Uninstall) {
	$SetupFile = "$SAPDir\SapSetup\Setup\NwSapSetup.exe"
	$Param = "/noDlg /all /uninstall"
	Write-Log $LogFile "Attempting to uninstall all SAP products (like GUI, ALD & WWI Hotfixes).  Please wait..."
	Write-Log $LogFile "Commandline : [$SetupFile $Param]"
	If (-not(Test-Path -Path $SetupFile)) {
		Write-Log $LogFile "SAP setup file [$SetupFile] does not exists on the PC.  Skipping uninstallation!"
		Exit-Script -ExitCode 8859
	}
	$ExitCode = (Start-Process -FilePath $SetupFile -ArgumentList $Param -Wait -PassThru -WindowStyle 'Normal').ExitCode
	Write-Log $LogFile "Execution was completed with return code [$ExitCode]."
	If ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 129 -or $ExitCode -eq 130) {
		$ExitCode = 0
		$RestartFlagRaised = $true
		Write-Log $LogFile "***   Restart of the PC is required.   ***"
	}
	ElseIf ($ExitCode -eq 144) {
		$ExitCode = 0
		Write-Log $LogFile "Error report has been created.  Verify recent installation logs from [$SAPDir\SapSetup\LOGs]."
	}
	ElseIf ($ExitCode -eq 145 -or $ExitCode -eq 146) {
		$ExitCode = 0
		$RestartFlagRaised = $true
		Write-Log $LogFile "Error report has been created and reboot is recommended.  Verify recent installation logs from [$SAPDir\SapSetup\LOGs]."
	}
	ElseIf ([string]::IsNullOrEmpty($ExitCode)) {
		$ExitCode = 30002
	}
	If ($RestartFlagRaised -and $AllowRebootPassThru) { $ExitCode = 3010 }
	Exit-Script -ExitCode $ExitCode
}

$RegPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall"
If ($OS.OSArchitecture -match '64') {
	$RegPath = "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
}

$SAPApps = @(
	(Get-ChildItem -Path $RegPath -ErrorAction 'SilentlyContinue' | Get-ItemProperty |
		Where-Object { $_.DisplayName -like "*SNC Client Encryption*" -or $_.DisplayName -like "*SAP*Business Client*" -or $_.DisplayName -like "*SAP Business Explorer*" -or $_.DisplayName -like "*SAP Easy Document Management System*" -or $_.DisplayName -like "*SAP 64Bit RFC Controls*" } |
		Select-Object 'DisplayName', 'DisplayVersion', 'UninstallString') | Sort-Object 'DisplayName'
)

If ($SAPApps.Length -gt 0) {
	$objApps = @()
	Foreach ($App in $SAPApps) {
		[array]$Param = @('/noDlg')
		$Values = ($App.UninstallString).Split("/").Trim()
		$Param += For ($i=1; $i -lt $Values.Length; $i++) { '/' + $Values[$i] }
		$objApps += (New-Object PSObject -Property ([ordered]@{
			Name = $App.DisplayName
			Version = $App.DisplayVersion
			FilePath = $Values[0] -Replace '"', ''
			ArgumentList = $Param
		}))
	}

	Foreach ($UninstCmd in $objApps) {
		[string]$SAPName = $UninstCmd.Name
		[string]$SAPVersion = $UninstCmd.Version
		[string]$SetupFile = $UninstCmd.FilePath
		[string]$Param = $UninstCmd.ArgumentList

		If (Test-Path -Path $SetupFile) {

			If ($SAPName -match '64Bit RFC Controls' -and $SAPVersion -ge '8.00') {
				Write-Log $LogFile "Latest version found [$SAPName] [$SAPVersion].  Skipping uninstallation."
				Continue
			}

			If ($SAPName -match 'SAP Business Explorer' -and $SAPVersion -ge '8.00') {
				Write-Log $LogFile "Latest version found [$SAPName] [$SAPVersion].  Skipping uninstallation."
				Continue
			}

			If ($SAPName -match 'SNC Client Encryption' -and $SAPVersion -ge '2.0.0.3') {
				Write-Log $LogFile "Latest version found [$SAPName] [$SAPVersion].  Skipping uninstallation."
				Continue
			}

			Write-Log $LogFile "Attempting to uninstall [$SAPName] [$SAPVersion].  Please wait..."
			Write-Log $LogFile "Commandline : [$SetupFile $Param]"
			$ExitCode = (Start-Process -FilePath $SetupFile -ArgumentList $Param -Wait -PassThru -WindowStyle 'Hidden').ExitCode
			Write-Log $LogFile "Execution was completed with return code [$ExitCode]."

			If ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 129 -or $ExitCode -eq 130) {
				$ExitCode = 0
				$RestartFlagRaised = $true
				Write-Log $LogFile "***   Restart of the PC is required.   ***"
				Start-Sleep -s 1
			}
			ElseIf ($ExitCode -eq 144) {
				$ExitCode = 0
				Write-Log $LogFile "Error report has been created.  Verify recent installation logs from [$SAPDir\SapSetup\LOGs]."
			}
			ElseIf ($ExitCode -eq 145 -or $ExitCode -eq 146) {
				$ExitCode = 0
				$RestartFlagRaised = $true
				Write-Log $LogFile "Error report has been created and reboot is recommended.  Verify recent installation logs from [$SAPDir\SapSetup\LOGs]."
			}
			Else {
				If ([string]::IsNullOrEmpty($ExitCode)) { $ExitCode = 30003 }
				Exit-Script -ExitCode $ExitCode
			}
		}
	}
}

$RestartFlagRaised = $false

# =============================================================================
# SOURCE LOCATION (CHANGED): Force SAP frontend package path to C:\SAPFrontend800_v18
# =============================================================================
$SAPFrontendSetupDir = "C:\SAPFrontend800_v18"
Write-Log $LogFile "Using SAP frontend source directory: [$SAPFrontendSetupDir]"

if (-not (Test-Path -Path $SAPFrontendSetupDir -PathType Container)) {
	Write-Log $LogFile "Source directory not found: [$SAPFrontendSetupDir]. Aborting."
	Exit-Script -ExitCode 30010
}

Write-Log $LogFile "Attempting to install $AppName $AppVersion.  Please wait..."

$SetupFile = Join-Path $SAPFrontendSetupDir "SAP_Frontend_8.00_20250424_1158.exe"
if (-not (Test-Path -Path $SetupFile -PathType Leaf)) {
	Write-Log $LogFile "Installer not found: [$SetupFile]. Aborting."
	Exit-Script -ExitCode 30011
}

Write-Log $LogFile "Commandline : [$SetupFile /noDlg /force]"
$ExitCode = (Start-Process -FilePath $SetupFile -ArgumentList "/noDlg /force" -Wait -PassThru -WindowStyle 'Normal').ExitCode

Write-Log $LogFile "Execution was completed with return code [$ExitCode]."
If ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 129 -or $ExitCode -eq 130) {
	$ExitCode = 0
	$RestartFlagRaised = $true
	Write-Log $LogFile "***   Restart of the PC is required.   ***"
	Start-Sleep -s 1
}
ElseIf ($ExitCode -eq 144) {
	$ExitCode = 0
	Write-Log $LogFile "Error report has been created.  Verify recent installation logs from [$SAPDir\SapSetup\LOGs]."
}
ElseIf ($ExitCode -eq 145 -or $ExitCode -eq 146) {
	$ExitCode = 0
	$RestartFlagRaised = $true
	Write-Log $LogFile "Error report has been created and reboot is recommended.  Verify recent installation logs from [$SAPDir\SapSetup\LOGs]."
}
Else {
	If ([string]::IsNullOrEmpty($ExitCode)) { $ExitCode = 30004 }
	Exit-Script -ExitCode $ExitCode
}

function UnPin-App {
	param([string]$appname)
	try {
		((New-Object -Com Shell.Application).NameSpace('shell:::{4234d49b-0245-4df3-b780-3893943456e1}').Items() | Where-Object {$_.Name -eq $appname}).Verbs() |
			Where-Object {$_.Name.replace('&','') -match 'Unpin from taskbar'} |
			ForEach-Object {$_.DoIt()} -ErrorAction SilentlyContinue
		return "App '$appname' unpinned from Taskbar"
	} catch { }
}

Write-Log $LogFile "Attempting to Delete taskbar pinned shortcut for Business Client  Please wait..."
UnPin-App "SAP Business Client 7.70"
Write-Log $LogFile "Execution was completed"

# FIXED: wrong dash in -Force, and restart Explorer cleanly
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process explorer.exe

Write-Log $LogFile "Attempting to import SAP registry.  Please wait..."
$SetupFile = "$envSystemRoot\REGEDIT.EXE"
$RegFile = Join-Path $SAPFrontendSetupDir "SAP_Frontend_800_Default_Settings.reg"

if (-not (Test-Path -Path $RegFile -PathType Leaf)) {
	Write-Log $LogFile "Registry file not found: [$RegFile]. Aborting."
	Exit-Script -ExitCode 30012
}

$Param = "/s `"$RegFile`""
$ExitCodeTemp = (Start-Process -FilePath $SetupFile -ArgumentList $Param -Wait -PassThru -WindowStyle 'Hidden').ExitCode
Write-Log $LogFile "Execution was completed with return code [$ExitCodeTemp]."
Start-Sleep -s 1

# Copy branding logos
$Source = Join-Path $SAPFrontendSetupDir "SAP_GUI_logos\*"
Write-Log $LogFile "Attempting to copy ADM branding logos from [$Source] to [$SAPDir].  Please wait..."
Ensure-Dir -Path $SAPDir
$null = Copy-Item -Path $Source -Destination "$SAPDir\" -Recurse -Force -ErrorAction 'SilentlyContinue'
Start-Sleep -s 1

# Copy WWI graphics
$Source = Join-Path $SAPFrontendSetupDir "WWI_GRAPHICS_20220512\*"
$WwiDest = "$SAPDir\FrontEnd\SAPgui\wwi\graphics\"
Write-Log $LogFile "Attempting to copy logos for EHS MSDS from [$Source] to [$WwiDest].  Please wait..."
Ensure-Dir -Path $WwiDest
$null = Copy-Item -Path $Source -Destination $WwiDest -Recurse -Force -ErrorAction 'SilentlyContinue'
Start-Sleep -s 1

# NWBC options
$Source = Join-Path $SAPFrontendSetupDir "NwbcOptions.xml"
$NWBCDir = Join-Path -Path $env:ProgramData -ChildPath "SAP\NWBC"
Write-Log $LogFile "Attempting to copy [$Source] to [$NWBCDir\].  Please wait..."
Ensure-Dir -Path $NWBCDir

If (Test-Path -Path "$NWBCDir\NwbcOptions.xml" -PathType 'Leaf') {
	If (-not(Test-Path -Path "$NWBCDir\NwbcOptions.xml.bak2" -PathType 'Leaf')) {
		$null = Rename-Item -Path "$NWBCDir\NwbcOptions.xml" -NewName "NwbcOptions.xml.bak2" -Force
	}
}
$null = Copy-Item -Path $Source -Destination "$NWBCDir\NwbcOptions.xml" -Force -ErrorAction 'SilentlyContinue'
Start-Sleep -s 1

Write-Log $LogFile "Deleting registry key [HKEY_CURRENT_USER\Software\SAP\SAPLogon\Options] value [LandscapeFileOnServer]..."
Delete-HKCURegFromAllProfiles -Key "Software\SAP\SAPLogon\Options" -Name "LandscapeFileOnServer"

$ProfilesFolder = "C:\Users"
$Saplogon = "AppData\Roaming\SAP\Common"
Foreach ($Profile in (Get-ChildItem $ProfilesFolder -Directory)) {
	$SAPFileColn = @()
	$DestinationFolder = Join-Path (Join-Path $ProfilesFolder $Profile) $Saplogon
	$SAPFileColn = "$DestinationFolder\SAPUILandscape.xml", "$DestinationFolder\SAPUILandscapeGlobal.xml", "$DestinationFolder\saplogon.ini"
	Foreach ($SAPFile in $SAPFileColn) {
		If (Test-Path -Path $SAPFile) {
			$FileDetails = Get-Item $SAPFile | Select-Object 'BaseName', 'Extension'
			$NewFileName =  "{0}{1}{2}" -f $FileDetails.BaseName, "-$($AppName -replace ' ','')", $FileDetails.Extension
			Write-Log $LogFile "Renaming [$SAPFile] to [$NewFileName]..."
			$null = Rename-Item -Path $SAPFile -NewName $NewFileName -Force -Confirm:$false -ErrorAction 'SilentlyContinue'
		}
	}
}

$DeleteFiles = @("$envSystemRoot\saplogon.ini", "$envSystemRoot\sapmsg.ini", "$envSystemRoot\saproute.ini")
Foreach ($DelFile in $DeleteFiles) {
	If (Test-Path -Path $DelFile) {
		Write-Log $LogFile "Deleting SAP ini file: [$DelFile]..."
		$null = Remove-Item -Path $DelFile -Force -Confirm:$false -ErrorAction 'SilentlyContinue'
	}
}

# Batch copy + RunOnce
$BatchSource = Join-Path $SAPFrontendSetupDir "Batch\*"
if (-not (Test-Path -Path (Join-Path $SAPFrontendSetupDir "Batch") -PathType Container)) {
	Write-Log $LogFile "Batch folder not found: [$($SAPFrontendSetupDir)\Batch]. Skipping batch copy."
}
else {
	Copy-Item -Path $BatchSource -Destination "C:\ProgramData" -Force -ErrorAction SilentlyContinue
	Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" -Name 'SapLogon' -Value "C:\ProgramData\run_SAP.bat"
}

Write-Log $LogFile "Installation of $AppName $AppVersion has completed successfully."
If ($RestartFlagRaised) {
	Write-Log $LogFile "*****   Restart of the PC is required, prior working on the application   *****"
	If ($AllowRebootPassThru) { $ExitCode = 3010 }
}

Exit-Script -ExitCode $ExitCode
