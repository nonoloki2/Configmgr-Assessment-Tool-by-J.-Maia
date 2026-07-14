# Nome do computador (hostname)
$hostname = "250L7Z2B2J3"

try {
    # Obter o objeto do computador no AD
    $computer = Get-ADComputer -Identity $hostname

    # Obter os grupos dos quais o computador é membro
    $groups = Get-ADPrincipalGroupMembership -Identity $computer

    # Exibir os nomes dos grupos
    $groups | Select-Object Name, DistinguishedName
}
catch {
    Write-Warning "Não foi possível localizar o computador '$hostname' ou obter seus grupos. Erro: $_"
}