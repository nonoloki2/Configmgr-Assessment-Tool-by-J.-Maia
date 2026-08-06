# Verify PowerShell is running as an Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
If ( ( $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) ) -eq $false ) { Write-Warning "PowerShell must be executed as administrator"; Start-Sleep 3 }
 
# Timer function
Function Timer { Param ( $Seconds, $Legend )
For( $i = 1; $i -le $Seconds; $i++) { Write-Progress -Activity "$Legend ($Seconds secs)." -status "$i secs..." -percentComplete ($i / $Seconds*100); Start-Sleep -Seconds 1 } }
 
# Reset Group Policy objects (i.e., Registry.pol)
Remove-Item $env:windir\system32\GroupPolicyUsers -Recurse -force -ErrorAction SilentlyContinue
Remove-Item $env:windir\system32\GroupPolicy -Recurse -force -ErrorAction SilentlyContinue
gpupdate /force
 
# Stop the Windows Update agent and related services
If ( ( Get-Service -Name BITS ).Status -eq "Running" ) { Stop-Service -Name BITS -Force -Confirm:$False -ErrorAction SilentlyContinue }
$ID = Get-WmiObject -Class Win32_Service -Filter "Name LIKE 'wuauserv'" | Select-Object -ExpandProperty ProcessId
If ( $ID -ne 0 ) { taskkill /pid $ID /F }
Set-Service -Name wuauserv -StartupType Disabled -Confirm:$False -ErrorAction SilentlyContinue
If ( ( Get-Service -Name AppIDSvc ).Status -eq "Running" ) { Stop-Service -Name AppIDSvc -Force -Confirm:$False -ErrorAction SilentlyContinue }
$ID = Get-WmiObject -Class Win32_Service -Filter "Name LIKE 'CryptSvc'" | Select-Object -ExpandProperty ProcessId
If ( $ID -ne 0 ) { taskkill /pid $ID /F }
Set-Service -Name CryptSvc -StartupType Disabled -Confirm:$False -ErrorAction SilentlyContinue
If ( Test-Path -Path $env:SystemRoot\system32\Catroot2 -ErrorAction SilentlyContinue ) { Remove-Item -Path $env:SystemRoot\system32\Catroot2 -Recurse -Force -Confirm:$False -ErrorAction SilentlyContinue }
If ( Test-Path -Path $env:ALLUSERSPROFILE\Microsoft\Network\Downloader -ErrorAction SilentlyContinue ) { Remove-Item -Path $env:ALLUSERSPROFILE\Microsoft\Network\Downloader -Recurse -Force -Confirm:$False -ErrorAction SilentlyContinue }
If ( Test-Path -Path C:\ProgramData\Microsoft\Network\Downloader -ErrorAction SilentlyContinue ) { Remove-Item -Path C:\ProgramData\Microsoft\Network\Downloader -Recurse -Force -Confirm:$False -ErrorAction SilentlyContinue }
If ( Test-Path -Path $env:SystemRoot\SoftwareDistribution -ErrorAction SilentlyContinue ) { Remove-Item -Path $env:SystemRoot\SoftwareDistribution -Recurse -Force -Confirm:$False -ErrorAction SilentlyContinue }
 
# Register the required Dll files
regsvr32.exe /s $env:SystemRoot\System32\atl.dll
regsvr32.exe /s $env:SystemRoot\System32\urlmon.dll
regsvr32.exe /s $env:SystemRoot\System32\mshtml.dll
regsvr32.exe /s $env:SystemRoot\System32\shdocvw.dll
regsvr32.exe /s $env:SystemRoot\System32\browseui.dll
regsvr32.exe /s $env:SystemRoot\System32\jscript.dll
regsvr32.exe /s $env:SystemRoot\System32\vbscript.dll
regsvr32.exe /s $env:SystemRoot\System32\scrrun.dll
regsvr32.exe /s $env:SystemRoot\System32\msxml.dll
regsvr32.exe /s $env:SystemRoot\System32\msxml3.dll
regsvr32.exe /s $env:SystemRoot\System32\msxml6.dll
regsvr32.exe /s $env:SystemRoot\System32\actxprxy.dll
regsvr32.exe /s $env:SystemRoot\System32\softpub.dll
regsvr32.exe /s $env:SystemRoot\System32\wintrust.dll
regsvr32.exe /s $env:SystemRoot\System32\dssenh.dll
regsvr32.exe /s $env:SystemRoot\System32\rsaenh.dll
regsvr32.exe /s $env:SystemRoot\System32\gpkcsp.dll
regsvr32.exe /s $env:SystemRoot\System32\sccbase.dll
regsvr32.exe /s $env:SystemRoot\System32\slbcsp.dll
regsvr32.exe /s $env:SystemRoot\System32\cryptdlg.dll
regsvr32.exe /s $env:SystemRoot\System32\oleaut32.dll
regsvr32.exe /s $env:SystemRoot\System32\ole32.dll
regsvr32.exe /s $env:SystemRoot\System32\shell32dll
regsvr32.exe /s $env:SystemRoot\System32\initpki.dll
regsvr32.exe /s $env:SystemRoot\System32\wuapi.dll
regsvr32.exe /s $env:SystemRoot\System32\wuaueng.dll
regsvr32.exe /s $env:SystemRoot\System32\wuaueng1.dll
regsvr32.exe /s $env:SystemRoot\System32\wucltui.dll
regsvr32.exe /s $env:SystemRoot\System32\wups.dll
regsvr32.exe /s $env:SystemRoot\System32\wups2.dll
regsvr32.exe /s $env:SystemRoot\System32\wuweb.dll
regsvr32.exe /s $env:SystemRoot\System32\qmgr.dll
regsvr32.exe /s $env:SystemRoot\System32\qmgrprxy.dll
regsvr32.exe /s $env:SystemRoot\System32\wucltux.dll
regsvr32.exe /s $env:SystemRoot\System32\muweb.dll
regsvr32.exe /s $env:SystemRoot\System32\wuwebv.dll
 
# Remove old WUAgent info from the device
If ( Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name SusClientId -ErrorAction SilentlyContinue ) { Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name SusClientId -ErrorAction Continue -Force -Confirm:$False }
If ( Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name SusClientIdValidation -ErrorAction SilentlyContinue ) { Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name SusClientIdValidation -ErrorAction Continue -Force -Confirm:$False }
If ( Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name AccountDomainSid -ErrorAction SilentlyContinue ) { Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name AccountDomainSid -ErrorAction Continue -Force -Confirm:$False }
If ( Get-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name PingID -ErrorAction SilentlyContinue ) { Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate -Name PingID -ErrorAction Continue -Force -Confirm:$False }
If ( Test-Path -Path $env:SystemRoot\Logs\WindowsUpdate -ErrorAction SilentlyContinue ) { Remove-Item -Path $env:SystemRoot\Logs\WindowsUpdate -Recurse -Force -Confirm:$False -ErrorAction Continue }
If ( Test-Path -Path $env:SystemRoot\WindowsUpdate.log -ErrorAction SilentlyContinue ) { Remove-Item -Path $env:SystemRoot\WindowsUpdate.log -Recurse -Force -Confirm:$False }
 
# Restart the needed services
Start-Service -Name BITS -Confirm:$False -ErrorAction SilentlyContinue
Set-Service -Name wuauserv -StartupType Automatic -Confirm:$False -ErrorAction SilentlyContinue
Start-Service -Name wuauserv -Confirm:$False -ErrorAction SilentlyContinue
Start-Service -Name AppIDSvc -Confirm:$False -ErrorAction SilentlyContinue
Set-Service -Name CryptSvc -StartupType Manual -Confirm:$False -ErrorAction SilentlyContinue
Start-Service -Name CryptSvc -Confirm:$False -ErrorAction SilentlyContinue
 
# Refresh and resend the ComplianceState of the device
$SCCMUpdatesStore = New-Object -ComObject Microsoft.CCM.UpdatesStore
$SCCMUpdatesStore.RefreshServerComplianceState()
 
# Client actions
#
# Trigger the Software Update Scan action
([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000113}')
# Trigger the software update deployment evaluation 
([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000108}')
# Trigger the Inventory agent
([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000001}')
# Trigger the State Message Manager
([wmiclass]'ROOT\ccm:SMS_Client').TriggerSchedule('{00000000-0000-0000-0000-000000000111}')
 
# Re-register the WUAgent info with WSUS
Wuauclt /resetauthorization /detectnow
Wuauclt /detectnow /reportnow