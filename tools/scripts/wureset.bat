:: ==================================================================================
:: NAME:      Reset Windows Update Tool (Windows 8, 8.1, 10, 11)
:: DESCRIPTION:  Reset Windows Update Components, Winsock, Proxy, Registry keys, etc.
:: AUTHOR:    Manuel Gil (updated for Windows 11 by ChatGPT)
:: ==================================================================================

@echo off
title Reset Windows Update Tool (Win10/11)
mode con cols=100 lines=40
color 17
cls

goto getValues
goto :eof


:: ============================================================
:: Print helper
:: ============================================================
:print
cls
echo.
echo.%name% [Version: %version%]
echo.Reset Windows Update Tool.
echo.
echo.%*
echo.
goto :eof


:: ============================================================
:: Registry add helper
:: ============================================================
:addReg
reg add "%~1" /v "%~2" /t "%~3" /d "%~4" /f >nul 2>&1
goto :eof


:: ============================================================
:: Get OS info (updated for Windows 11)
:: ============================================================
:getValues
for /f "tokens=4 delims=[] " %%a in ('ver') do set version=%%a

ver | find "10.0." > nul
if %errorlevel% EQU 0 (
    for /f "tokens=4 delims=.[] " %%a in ('ver') do set build=%%a
    ver | find "Build 22" > nul
    if %errorlevel% EQU 0 (
        set name=Microsoft Windows 11
    ) else (
        set name=Microsoft Windows 10
    )
    set family=10
    set allow=Yes
) else (
    ver | find "6.3." > nul
    if %errorlevel% EQU 0 (
        set name=Microsoft Windows 8.1
        set family=8
        set allow=Yes
    ) else (
        ver | find "6.2." > nul
        if %errorlevel% EQU 0 (
            set name=Microsoft Windows 8
            set family=8
            set allow=Yes
        ) else (
            set name=Unknown
            set allow=No
        )
    )
)

call :print %name% detected . . .

if /I "%allow%"=="Yes" goto permission

call :print Sorry, this Operating System is not supported.
echo.
echo.  Detected version: %version%
echo.  Only Windows 8, 8.1, 10, or 11 are supported.
echo.
echo.Press any key to exit . . .
pause>nul
exit /b
goto :eof


:: ============================================================
:: Check Admin rights
:: ============================================================
:permission
openfiles >nul 2>&1
if %errorlevel% EQU 0 (
    goto terms
) else (
    call :print Checking for Administrator elevation.
    echo.    You are not running as Administrator.
    echo.    Please right-click and select "Run as Administrator".
    echo.
    echo.Press any key to exit . . .
    pause>nul
    exit /b
)
goto :eof


:: ============================================================
:: Terms
:: ============================================================
:terms
call :print Terms and Conditions of Use.

echo. The methods inside this tool modify system files and registry keys.
echo. Use at your own risk. No warranty provided.
echo.
choice /c YN /n /m "Do you want to continue (Y/N)? "
if %errorlevel% EQU 1 goto menu
if %errorlevel% EQU 2 exit /b
goto :eof


:: ============================================================
:: Main menu
:: ============================================================
:menu
call :print This tool resets Windows Update components and network settings.
echo. 1. Reset Windows Update Components
echo. 2. Delete Temporary Files
echo. 3. Reset Winsock and Network Stack
echo. 4. Run DISM /RestoreHealth
echo. 5. Run SFC /Scannow
echo. 6. Force Windows Update Check
echo. 7. Open Windows Update Settings
echo. 8. Restart Computer
echo.
echo. 0. Exit
echo.
set /p option=Select an option: 

if "%option%"=="1" call :components
if "%option%"=="2" call :temp
if "%option%"=="3" call :winsock
if "%option%"=="4" call :dism3
if "%option%"=="5" call :sfc
if "%option%"=="6" call :updates
if "%option%"=="7" start ms-settings:windowsupdate
if "%option%"=="8" call :restart
if "%option%"=="0" exit /b

goto menu


:: ============================================================
:: Reset Windows Update components
:: ============================================================
:components
call :print Resetting Windows Update Components...
net stop bits >nul 2>&1
net stop wuauserv >nul 2>&1
net stop cryptsvc >nul 2>&1
taskkill /im wuauclt.exe /f >nul 2>&1

echo Deleting old data...
rd /s /q "%systemroot%\SoftwareDistribution" >nul 2>&1
rd /s /q "%systemroot%\system32\catroot2" >nul 2>&1

echo Resetting service descriptors...
sc.exe sdset wuauserv D:(A;;CCDCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRRC;;;BA)
sc.exe sdset bits D:(A;;CCDCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRRC;;;BA)

echo Restarting services...
net start bits >nul 2>&1
net start wuauserv >nul 2>&1
net start cryptsvc >nul 2>&1

echo.
echo Windows Update components have been reset successfully.
pause
goto :eof


:: ============================================================
:: Delete temporary files
:: ============================================================
:temp
call :print Deleting temporary files...
del /f /s /q "%TEMP%\*.*" >nul 2>&1
del /f /s /q "%systemroot%\Temp\*.*" >nul 2>&1
echo Temporary files deleted.
pause
goto :eof


:: ============================================================
:: Winsock reset
:: ============================================================
:winsock
call :print Resetting Winsock and TCP/IP stack...
netsh winsock reset >nul
netsh int ip reset >nul
netsh advfirewall reset >nul
ipconfig /flushdns >nul
netsh winhttp reset proxy >nul
echo.
echo Network settings restored.
pause
goto :eof


:: ============================================================
:: Run SFC
:: ============================================================
:sfc
call :print Running System File Checker...
sfc /scannow
pause
goto :eof


:: ============================================================
:: Run DISM RestoreHealth
:: ============================================================
:dism3
call :print Running DISM RestoreHealth...
Dism.exe /Online /Cleanup-Image /RestoreHealth
pause
goto :eof


:: ============================================================
:: Force update check
:: ============================================================
:updates
call :print Forcing Windows Update check...
wuauclt /resetauthorization /detectnow
usoclient StartScan
echo.
echo Update detection triggered.
pause
goto :eof


:: ============================================================
:: Restart system
:: ============================================================
:restart
call :print Restarting your PC in 60 seconds...
shutdown /r /t 60 /c "System will restart in 60 seconds."
pause
goto :eof
