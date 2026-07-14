# Define a URL e o caminho de destino
$updateUrl = "https://catalog.s.download.windowsupdate.com/d/msdownload/update/software/secu/2025/09/windows8.1-kb5065507-x64_33347a18ca7ae0d713252688e2caa2245371106f.msu"
$destinationPath = "C:\windows8.1-kb5065507-x64_33347a18ca7ae0d713252688e2caa2245371106f.msu"

# Baixa o arquivo
Invoke-WebRequest -Uri $updateUrl -OutFile $destinationPath

# Aguarda o download terminar e instala o update silenciosamente
Start-Process "wusa.exe" -ArgumentList "$destinationPath /quiet /norestart" -Wait