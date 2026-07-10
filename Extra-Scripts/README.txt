GET-FREBERRORS - PSEXEC
=========================

Arquivos:
- Get-FREBErrors.ps1
- RemoteCollector.ps1
- hosts.txt
- PsExec.exe ou PsExec64.exe (não incluído)

Estrutura recomendada:
E:\scripts\
  Get-FREBErrors.ps1
  RemoteCollector.ps1
  hosts.txt
  PsExec64.exe

hosts.txt:
njtrngapsp001
njtrngapsp002
njtrngapsp003

Execução:
powershell.exe -ExecutionPolicy Bypass -File E:\scripts\Get-FREBErrors.ps1

Últimos 30 dias:
powershell.exe -ExecutionPolicy Bypass -File E:\scripts\Get-FREBErrors.ps1 -DaysBack 30

PsExec em outro caminho:
powershell.exe -ExecutionPolicy Bypass -File E:\scripts\Get-FREBErrors.ps1 -PsExecPath C:\Sysinternals\PsExec64.exe

Saída:
E:\scripts\FREB_Reports\FREB_Errors_yyyyMMdd_HHmmss.csv
E:\scripts\FREB_Reports\FREB_ScanStatus_yyyyMMdd_HHmmss.csv

Observação:
O PsExec deve conseguir executar comandos remotos no servidor. O coletor lê localmente:
C:\inetpub\logs\FailedReqLogFiles
