# Força o cliente SCCM a comunicar com o Management Point
# Deve ser executado em modo elevado (Run as Administrator)

Write-Host "Forcing communication to Management Point..." -ForegroundColor Cyan

$guids = @(
    "{00000000-0000-0000-0000-000000000113}", # Machine Policy Retrieval
    "{00000000-0000-0000-0000-000000000114}", # Machine Policy Evaluation
    "{00000000-0000-0000-0000-000000000121}"  # Software Updates Deployment Evaluation
)

foreach ($g in $guids) {
    Write-Host "Disparando trigger $g" -ForegroundColor Yellow
    Invoke-WmiMethod -Namespace "root\ccm" -Class "SMS_Client" -Name "TriggerSchedule" -ArgumentList $g | Out-Null
}

# Opcional: reinicia o serviço do cliente para reforçar a comunicação
Restart-Service -Name ccmexec -Force

Write-Host "Comunication done it! Please verify the LocationServices.log." -ForegroundColor Green

# Reinicia o serviço ccmexec
Restart-Service -Name ccmexec -Force

Write-Host "Agent Restarted" -ForegroundColor Green
