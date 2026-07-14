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