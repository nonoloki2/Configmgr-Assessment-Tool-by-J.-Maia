# Executa em modo silencioso e elevado
$ErrorActionPreference = 'Stop'

# Força TLS 1.2 para evitar problemas de conexão
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

# Configura proxy somente se existir
if ([System.Net.WebRequest]::DefaultWebProxy.Address) {
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
}

# Instala e importa NuGet provider
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Import-PackageProvider -Name NuGet -Force

# Garante que PSGallery esteja confiável
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Instala PSWindowsUpdate se não existir
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-Module -Name PSWindowsUpdate -Force -AllowClobber
}

# Importa módulo
Import-Module PSWindowsUpdate

# Executa atualização do Windows
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose

