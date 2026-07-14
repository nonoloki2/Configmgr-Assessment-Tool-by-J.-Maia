# Executa em modo silencioso e elevado
$ErrorActionPreference = 'Stop'

# Instala o NuGet provider sem confirmação
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser

# Garante que o repositório PSGallery esteja confiável
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

# Instala o módulo PSWindowsUpdate se ainda não estiver instalado
if (-not (Get-InstalledModule -Name PSWindowsUpdate -ErrorAction SilentlyContinue)) {
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false -Scope CurrentUser -AllowClobber
}

# Executa atualização do Windows sem prompts e sem reiniciar
Import-Module PSWindowsUpdate
Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -Verbose