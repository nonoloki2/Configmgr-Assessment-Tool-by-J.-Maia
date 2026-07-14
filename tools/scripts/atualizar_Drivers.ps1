if ($drivers.Count -gt 0) {
    Install-WindowsUpdate -Updates $drivers -IgnoreReboot -AcceptAll
} else {
    Write-Host "Nenhuma atualização de driver disponível."
}