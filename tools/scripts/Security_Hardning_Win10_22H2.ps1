# Path for log file
$LogPath = "C:\Hardening_Log.txt"
Add-Content $LogPath "`n--- Hardening started: $(Get-Date) ---`n"

# Function to apply registry fix and log the result
function Apply-RegistryFix {
    param (
        [string]$Path,
        [string]$Name,
        [int]$Value
    )
    try {
        if (!(Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value
        Add-Content $LogPath "✔ $Path\$Name set to $Value"
    } catch {
        Add-Content $LogPath "❌ Failed to set $Path\$Name: $_"
    }
}

# Disable TLS 1.1 (client and server)
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server" -Name "Enabled" -Value 0
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client" -Name "Enabled" -Value 0

# Disable 3DES cipher
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\Triple DES 168" -Name "Enabled" -Value 0

# Disable DES cipher
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\DES 56/56" -Name "Enabled" -Value 0

# Disable MD5 hash algorithm
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Hash\MD5" -Name "Enabled" -Value 0

# Enforce SMBv2 signing (client and server)
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name "RequireSecuritySignature" -Value 1
Apply-RegistryFix -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "RequireSecuritySignature" -Value 1

# Final log entry
Add-Content $LogPath "`n--- Hardening completed: $(Get-Date) ---`n"
Write-Host "✅ Hardening applied. Check the log at: $LogPath"