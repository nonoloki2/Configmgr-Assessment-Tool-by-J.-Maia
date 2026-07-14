# Executar como Administrador
Write-Host "Parando os serviços relacionados ao WMI..." -ForegroundColor Cyan
Stop-Service -Name winmgmt -Force

Write-Host "Renomeando o repositório WMI corrompido..." -ForegroundColor Cyan
$repositoryPath = "$env:windir\System32\wbem\Repository"
if (Test-Path $repositoryPath) {
    Rename-Item -Path $repositoryPath -NewName "Repository.old" -Force
    Write-Host "Repositório renomeado com sucesso." -ForegroundColor Green
} else {
    Write-Host "Repositório WMI não encontrado." -ForegroundColor Yellow
}

Write-Host "Reiniciando o serviço WMI..." -ForegroundColor Cyan
Start-Service -Name winmgmt

Write-Host "Recompilando os arquivos MOF..." -ForegroundColor Cyan
$wbemPath = "$env:windir\System32\wbem"
cd $wbemPath
$files = Get-ChildItem -Filter *.mof
foreach ($file in $files) {
    Write-Host "Compilando: $($file.Name)" -ForegroundColor Gray
    mofcomp $file.FullName
}

Write-Host "Repositório WMI reconstruído com sucesso!" -ForegroundColor Green

## Reinstalling agent

Write-Host "Desinstalando o cliente SCCM..." -ForegroundColor Cyan
$SCCMUninstallPath = "$env:windir\ccmsetup\ccmsetup.exe"
if (Test-Path $SCCMUninstallPath) {
    & $SCCMUninstallPath /uninstall
    Write-Host "Comando de desinstalação executado." -ForegroundColor Green
    Start-Sleep -Seconds 30
} else {
    Write-Host "Cliente SCCM não encontrado para desinstalação." -ForegroundColor Yellow
}


Write-Host "Removendo arquivos residuais do cliente SCCM..." -ForegroundColor Cyan

# Caminho correto: C:\Windows
$windowsPath = "$env:windir"

# Excluir SMSCFG.ini
$smscfgFile = Join-Path $windowsPath "SMSCFG.ini"
if (Test-Path $smscfgFile) {
    Remove-Item $smscfgFile -Force
    Write-Host "Arquivo SMSCFG.ini removido." -ForegroundColor Green
} else {
    Write-Host "Arquivo SMSCFG.ini não encontrado." -ForegroundColor Yellow
}

# Excluir arquivos .mif que começam com SMSAdvancedClient
$mifFiles = Get-ChildItem -Path $windowsPath -Filter "SMSAdvancedClient*.mif" -ErrorAction SilentlyContinue
if ($mifFiles.Count -gt 0) {
    foreach ($file in $mifFiles) {
        Remove-Item $file.FullName -Force
        Write-Host "Arquivo removido: $($file.Name)" -ForegroundColor Gray
    }
    Write-Host "Arquivos .mif removidos com sucesso." -ForegroundColor Green
} else {
    Write-Host "Nenhum arquivo .mif correspondente encontrado." -ForegroundColor Yellow
}

Write-Host "Instalando o cliente SCCM..." -ForegroundColor Cyan
$SCCMInstallPath = "\\maznasccmp01.na.admworld.com\client\ccmsetup.exe"
if (Test-Path $SCCMInstallPath) {
    & $SCCMInstallPath /mp:MAZNASCCMP01.na.admworld.com SMSSITECODE=PR1 /forceinstall
    Write-Host "Instalação do cliente SCCM iniciada." -ForegroundColor Green
} else {
    Write-Host "Caminho de instalação do cliente SCCM não encontrado." -ForegroundColor Red
}
