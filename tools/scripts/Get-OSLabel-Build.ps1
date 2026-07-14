# Obter edição do Windows (ex: Enterprise)
$Edition = (Get-WmiObject -Class Win32_OperatingSystem).Caption

# Obter versão numérica (ex: 10.0.19045)
$Version = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").ReleaseId
$Build = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").CurrentBuild

# Obter nome do release (ex: 22H2)
$Release = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion

# Montar resultado
Write-Host "Sistema Operacional: $Edition"
Write-Host "Release: $Release"
Write-Host "Build: $Build"