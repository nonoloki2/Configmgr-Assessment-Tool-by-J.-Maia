# ⚙️ CONFIGURAÇÃO NO CLIENTE

# Exigir assinatura SMB no cliente
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name RequireSecuritySignature -Value 1

# Habilitar assinatura SMB no cliente
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" -Name EnableSecuritySignature -Value 1

# ⚙️ CONFIGURAÇÃO NO SERVIDOR

# Exigir assinatura SMB no servidor
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name RequireSecuritySignature -Value 1

# Habilitar assinatura SMB no servidor
Set-SmbServerConfiguration -EnableSecuritySignature $true

