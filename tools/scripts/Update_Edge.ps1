# Configurações iniciais
$ErrorActionPreference = 'Stop'

# Caminhos e URLs
$EdgeUrl = "https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/d524a684-223c-4353-ac48-352850f50294/MicrosoftEdgeEnterpriseX64.msi"
$InstallerPath = "C:\MicrosoftEdgeEnterpriseX64.msi"
$EdgeExecutable = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

# Verifica se o Edge já está instalado
if (Test-Path $EdgeExecutable) {
    Write-Host "🟢 Microsoft Edge já está instalado em seu sistema."
    return
}

# Baixa o instalador
Write-Host "🔽 Baixando Microsoft Edge Enterprise..."
Invoke-WebRequest -Uri $EdgeUrl -OutFile $InstallerPath

# Instala silenciosamente
Write-Host "⚙️ Instalando Microsoft Edge..."
$arguments = "/i `"$InstallerPath`" /quiet /norestart"quiet
Start-Process "msiexec.exe" -ArgumentList $arguments -Wait

# Verifica se foi instalado com sucesso
if (Test-Path $EdgeExecutable) {
    Write-Host "✅ Microsoft Edge instalado com sucesso."
} else {
    Write-Host "❌ Falha na instalação do Microsoft Edge."
}

# Remove o instalador (opcional)
if (Test-Path $InstallerPath) {
    Remove-Item $InstallerPath -Force
    Write-Host "🧹 Instalador removido."
}