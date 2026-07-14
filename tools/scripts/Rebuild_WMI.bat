@echo off
SETLOCAL

echo.
echo [*] Verificando privilegios de administrador...
>nul 2>&1 net session
if %errorlevel% neq 0 (
    echo ERRO: Este script precisa ser executado como Administrador.
    exit /b 1
)

set "FAILED=0"

echo.
echo [1/5] Parando o servico WMI (winmgmt)...
net stop winmgmt /y

echo.
echo [2/5] Renomeando repositorio WMI (se existir)...
set "REPO=%windir%\System32\wbem\Repository"
if exist "%REPO%\" (
    if exist "%REPO%.old" (
        echo Aviso: Ja existe Repository.old. Apague ou renomeie manualmente.
        set FAILED=1
    ) else (
        ren "%REPO%" "Repository.old"
        if %errorlevel% neq 0 (
            echo ERRO: Nao foi possivel renomear "%REPO%".
            set FAILED=1
        ) else (
            echo Repositorio renomeado para Repository.old
        )
    )
) else (
    echo Nao encontrado repositorio em "%REPO%". Pulando renomeacao.
)

echo.
echo [3/5] Reiniciando servico WMI...
net start winmgmt

echo.
echo [4/5] Recompilando arquivos MOF em %windir%\System32\wbem ...
pushd "%windir%\System32\wbem"
for %%F in (*.mof) do (
    echo Compilando: %%F
    mofcomp "%%F"
    if errorlevel 1 (
        echo ERRO: falha ao compilar %%F
        set FAILED=1
    )
)
popd

echo.
if %FAILED%==0 (
    echo SUCESSO: Repositorio WMI reconstruido e MOFs compilados.
    exit /b 0
) else (
    echo FALHA: Alguns passos apresentaram erro. Verifique mensagens acima.
    exit /b 1
)

ENDLOCAL
