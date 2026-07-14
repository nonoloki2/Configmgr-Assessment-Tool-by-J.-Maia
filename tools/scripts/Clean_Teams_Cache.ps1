# Fecha o Microsoft Teams se estiver em execução
Get-Process Teams -ErrorAction SilentlyContinue | Stop-Process -Force

# Define o caminho do cache do Teams
$teamsCachePath = "$env:APPDATA\Microsoft\Teams"

# Lista de pastas a serem limpas
$foldersToDelete = @(
    "blob_storage",
    "Cache",
    "databases",
    "GPUCache",
    "IndexedDB",
    "Local Storage",
    "tmp"
)

# Remove os arquivos das pastas especificadas
foreach ($folder in $foldersToDelete) {
    $fullPath = Join-Path $teamsCachePath $folder
    if (Test-Path $fullPath) {
        Remove-Item "$fullPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Cache limpo em: $fullPath"
    } else {
        Write-Host "Pasta não encontrada: $fullPath"
    }
}

Write-Host "Cache do Microsoft Teams limpo com sucesso!"