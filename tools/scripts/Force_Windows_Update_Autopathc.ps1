<#
.SYNOPSIS
    Atualiza o Windows usando o UsoClient e verifica se é necessário reiniciar.
.DESCRIPTION
    Script compatível com Windows Server 2012 R2, 2016, 2019 e 2022.
    Executa varredura, download e instalação de atualizações do Windows.
    Inclui logs, verificação de UsoClient e detecção de reinício pendente.
#>

# ===========================
# Executa em modo elevado e silencioso
# ===========================
$ErrorActionPreference = 'Stop'
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Iniciando processo de atualização..." -ForegroundColor Cyan

# Força o uso de TLS 1.2 para conexões HTTPS (compatibilidade com serviços modernos)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11

# ===========================
# Verifica se UsoClient está disponível
# ===========================
if (Get-Command UsoClient -ErrorAction SilentlyContinue) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] UsoClient detectado. Iniciando sequência de atualização..." -ForegroundColor Cyan

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Procurando atualizações disponíveis..." -ForegroundColor Cyan
    UsoClient StartScan
    Start-Sleep -Seconds 20

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Baixando atualizações..." -ForegroundColor Cyan
    UsoClient StartDownload
    Start-Sleep -Seconds 60

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Instalando atualizações..." -ForegroundColor Cyan
    UsoClient StartInstall
    Start-Sleep -Seconds 60

    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Processo de atualização concluído." -ForegroundColor Green
    Write-Host "Verificando se há reinicialização pendente..." -ForegroundColor Yellow

    # ===========================
    # Verifica se há reinício pendente
    # ===========================
    $needsReboot = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -ErrorAction SilentlyContinue
    if ($needsReboot) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ⚠️ O sistema requer reinicialização para concluir as atualizações." -ForegroundColor Yellow
    } else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✅ Nenhuma reinicialização necessária no momento." -ForegroundColor Green
    }

} else {
    # ===========================
    # Caso UsoClient não esteja disponível
    # ===========================
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ O comando UsoClient não foi encontrado neste sistema." -ForegroundColor Red
    Write-Host "Alternativa: execute Windows Update manualmente ou via PSWindowsUpdate." -ForegroundColor Yellow
    Write-Host "Para instalar PSWindowsUpdate:" -ForegroundColor Yellow
    Write-Host "Install-Module -Name PSWindowsUpdate -Force" -ForegroundColor Cyan
}

# ===========================
# Encerramento
# ===========================
Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Script finalizado." -ForegroundColor Cyan
