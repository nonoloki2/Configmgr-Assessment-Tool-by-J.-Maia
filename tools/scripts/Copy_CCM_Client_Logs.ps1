$Logshare = "\\LDCSCCMRDS1\Logs"
#Get path for SCCM client Log files
$Logpath = Get-ItemProperty -path HKLM:\Software\Microsoft\CCM\Logging\@Global
$Log = $logpath.LogDirectory

#Create folders
New-Item -Path $env:temp\SCCMLogs -ItemType Directory -Force
Copy-item -path $log\* -destination $env:temp\Sccmlogs -Force

#Create a .zip archive with sccm logs
Compress-Archive -Path $env:temp\Sccmlogs\* -CompressionLevel Optimal -DestinationPath $env:temp\sccmlogs

#Copy zipped logfile to servershare
$Computerlogshare=$logshare + “\” + $env:Computername
Write-host $Computerlogshare
New-Item -Path $Computerlogshare -ItemType Directory -Force
Copy-Item $env:temp\sccmlogs.zip -Destination $Computerlogshare -force

#Cleanup temporary files/folders
Remove-Item $env:temp\SCCMlogs -Recurse
Remove-item $env:temp\SCCMlogs.zip