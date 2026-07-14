# Para processos
Get-Process ccmsetup, ccmexec -ErrorAction SilentlyContinue | Stop-Process -Force

# Para serviços (se existirem)
"ccmexec","ccmsetup","smstsmgr","cmrcservice" | ForEach-Object {
  $s = Get-Service $_ -ErrorAction SilentlyContinue
  if ($s) { Stop-Service $_ -Force -ErrorAction SilentlyContinue }
}

# Pastas e arquivo ini
Remove-Item "C:\Windows\CCM","C:\Windows\CCMSetup","C:\Windows\CCMCache" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\smscfg.ini" -Force -ErrorAction SilentlyContinue

# Registro
"HKLM:\SOFTWARE\Microsoft\CCM",
"HKLM:\SOFTWARE\Microsoft\CCMSetup",
"HKLM:\SOFTWARE\Microsoft\SMS" | ForEach-Object {
  if (Test-Path $_) { Remove-Item $_ -Recurse -Force }
}
