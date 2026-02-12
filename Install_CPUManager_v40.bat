@echo off
:: ============================================================================
:: CPU MANAGER AI v40 - INSTALATOR
:: Instaluje wszystkie komponenty i tworzy skroty na pulpicie
:: ============================================================================

:: 1. Sprawdzenie Administratora
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo ============================================
    echo     WYMAGANE UPRAWNIENIA ADMINISTRATORA
    echo ============================================
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: 2. Konfiguracja zmiennych
set "INSTALL_DIR=C:\CPUManager"
set "PS_CMD=pwsh.exe"

set "MAIN_SCRIPT=CPUManager_v40.ps1"
set "CONFIG_SCRIPT=CPUManager_Configurator_v40.ps1"
set "WIDGET_SCRIPT=Widget_v40.ps1"
set "COMPACT_SCRIPT=CompactMonitor_v40.ps1"

echo.
echo ============================================================
echo        CPU MANAGER AI v40 - INSTALACJA
echo ============================================================
echo.

:: 3. Tworzenie folderu
if not exist "%INSTALL_DIR%" (
    echo [1/10] Tworzenie folderu %INSTALL_DIR%...
    mkdir "%INSTALL_DIR%"
)

:: 4. Kopiowanie plikow
echo [2/10] Kopiowanie plikow...
call :CopyFile "%~dp0%MAIN_SCRIPT%"
call :CopyFile "%~dp0%CONFIG_SCRIPT%"
call :CopyFile "%~dp0%WIDGET_SCRIPT%"
call :CopyFile "%~dp0%COMPACT_SCRIPT%"

:: 5. Generowanie skryptow uruchomieniowych (Tryb Ukryty)

echo [3/10] Generowanie skryptow startowych (uzycie %PS_CMD%)...

:: Ustawienie, ktory plik ps1 startuje
set "PS_START_COMMAND=start "" %PS_CMD% -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "

(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo %PS_START_COMMAND%"%MAIN_SCRIPT%"
) > "%INSTALL_DIR%\Start_Engine.bat"
echo      - Start_Engine.bat [OK]

(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo %PS_START_COMMAND%"%WIDGET_SCRIPT%"
) > "%INSTALL_DIR%\Start_Widget.bat"
echo      - Start_Widget.bat [OK]

(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo %PS_START_COMMAND%"%COMPACT_SCRIPT%"
) > "%INSTALL_DIR%\Start_CompactMonitor.bat"
echo      - Start_CompactMonitor.bat [OK]

(
echo @echo off
echo cd /d "%INSTALL_DIR%"
echo %PS_START_COMMAND%"%CONFIG_SCRIPT%"
) > "%INSTALL_DIR%\Start_Configurator.bat"
echo      - Start_Configurator.bat [OK]

:: PLIK START_ALL.BAT
echo [4/10] Tworzenie skryptu Start_All.bat...
(
echo @echo off
echo echo Uruchamianie wszystkich modulow CPU Manager v40...
echo call "%INSTALL_DIR%\Start_Engine.bat"
echo timeout /t 1 /nobreak ^>nul
echo call "%INSTALL_DIR%\Start_Widget.bat"
echo timeout /t 1 /nobreak ^>nul
echo call "%INSTALL_DIR%\Start_CompactMonitor.bat"
echo timeout /t 1 /nobreak ^>nul
echo call "%INSTALL_DIR%\Start_Configurator.bat"
echo echo Wszystkie moduly uruchomiono. Okno zamknie sie automatycznie.
) > "%INSTALL_DIR%\Start_All.bat"
echo      - Start_All.bat [OK]

:: 6. Generowanie skryptu zatrzymujacego i odinstalowujacego

echo [5/10] Tworzenie skryptu Stop_All.bat...
(
echo @echo off
echo echo Zatrzymywanie wszystkich komponentow CPU Manager...
echo taskkill /F /IM pwsh.exe /T 2^>nul
echo powershell -Command "Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*CPU Manager*' } | Stop-Process -Force" 2^>nul
echo del /f /q "%INSTALL_DIR%\*.pid" 2^>nul
echo echo Gotowe!
) > "%INSTALL_DIR%\Stop_All.bat"

echo [6/10] Generowanie Uninstall_v40.bat...
(
echo @echo off
echo echo Zamykanie procesow przed odinstalowaniem...
echo call "%INSTALL_DIR%\Stop_All.bat" ^>nul
echo timeout /t 2 /nobreak ^>nul
echo echo Usuwanie plikow...
echo del /f /q "%INSTALL_DIR%\%MAIN_SCRIPT%"
echo del /f /q "%INSTALL_DIR%\%CONFIG_SCRIPT%"
echo del /f /q "%INSTALL_DIR%\%WIDGET_SCRIPT%"
echo del /f /q "%INSTALL_DIR%\%COMPACT_SCRIPT%"
echo del /f /q "%INSTALL_DIR%\Start_Engine.bat"
echo del /f /q "%INSTALL_DIR%\Start_Widget.bat"
echo del /f /q "%INSTALL_DIR%\Start_CompactMonitor.bat"
echo del /f /q "%INSTALL_DIR%\Stop_All.bat"
echo del /f /q "%INSTALL_DIR%\Start_Configurator.bat"
echo del /f /q "%INSTALL_DIR%\Start_All.bat"
echo del /f /q "%INSTALL_DIR%\config.json"
echo echo Usuwanie skrotow...
echo del /f /q "%USERPROFILE%\Desktop\CPU Manager Konfigurator.lnk"
echo del /f /q "%USERPROFILE%\Desktop\CPU Manager v40 (START WSZYSTKO).lnk"
echo echo Usuwanie zadania harmonogramu...
echo schtasks /delete /tn "CPU Manager v40 Autostart" /f ^>nul 2^>nul
echo schtasks /delete /tn "CPU Manager Widget v40 Autostart" /f ^>nul 2^>nul
echo schtasks /delete /tn "CPU Manager CompactMonitor v40 Autostart" /f ^>nul 2^>nul
echo schtasks /delete /tn "CPU Manager Configurator v40 Autostart" /f ^>nul 2^>nul
echo echo.
echo Odinstalowano pomyslnie.
echo pause
) > "%INSTALL_DIR%\Uninstall_v40.bat"

:: 7. Tworzenie skrotow na pulpicie
echo [7/10] Tworzenie skrotow na pulpicie...

:: 1. Skrot dla Konfiguratora
powershell -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut([Environment]::GetFolderPath('Desktop') + '\CPU Manager Konfigurator.lnk'); $s.TargetPath = '%INSTALL_DIR%\Start_Configurator.bat'; $s.WorkingDirectory = '%INSTALL_DIR%'; $s.IconLocation = 'shell32.dll,264'; $s.WindowStyle = 7; $s.Save()"
echo      - Skrot "CPU Manager Konfigurator" [OK]

:: 2. Skrot "START WSZYSTKO"
powershell -Command "$ws = New-Object -ComObject WScript.Shell; $s = $ws.CreateShortcut([Environment]::GetFolderPath('Desktop') + '\CPU Manager v40 (START WSZYSTKO).lnk'); $s.TargetPath = '%INSTALL_DIR%\Start_All.bat'; $s.WorkingDirectory = '%INSTALL_DIR%'; $s.IconLocation = 'shell32.dll,13'; $s.WindowStyle = 7; $s.Save()"
echo      - Skrot "CPU Manager v40 (START WSZYSTKO)" [OK]

:: 8. Harmonogram zadan (Autostart)
echo [8/10] Rejestracja w Harmonogramie Zadan...
schtasks /delete /tn "CPU Manager v40 Autostart" /f >nul 2>&1
schtasks /delete /tn "CPU Manager Widget v40 Autostart" /f >nul 2>&1
schtasks /delete /tn "CPU Manager CompactMonitor v40 Autostart" /f >nul 2>&1
schtasks /delete /tn "CPU Manager Configurator v40 Autostart" /f >nul 2>&1

schtasks /create /tn "CPU Manager v40 Autostart" /tr "\"%INSTALL_DIR%\Start_Engine.bat\"" /sc onlogon /rl HIGHEST /f >nul
schtasks /create /tn "CPU Manager Widget v40 Autostart" /tr "\"%INSTALL_DIR%\Start_Widget.bat\"" /sc onlogon /rl HIGHEST /f >nul
schtasks /create /tn "CPU Manager CompactMonitor v40 Autostart" /tr "\"%INSTALL_DIR%\Start_CompactMonitor.bat\"" /sc onlogon /rl HIGHEST /f >nul
schtasks /create /tn "CPU Manager Configurator v40 Autostart" /tr "\"%INSTALL_DIR%\Start_Configurator.bat\"" /sc onlogon /rl HIGHEST /f >nul

:: 9. Config domyslny
echo [9/10] Inicjalizacja konfiguracji...
if not exist "%INSTALL_DIR%\config.json" (
    echo {"AIEnabled":true,"ForceMode":"","SilentMax":1,"BalancedMin":39,"BalancedMax":99,"GameMax":99,"TurboMin":100,"ThermalLimit":85,"UpdateInterval":1000,"AppLaunchBoostTime":10} > "%INSTALL_DIR%\config.json"
)

echo.
echo ============================================================
echo        INSTALACJA ZAKONCZONA
echo ============================================================
echo.

:: 10. AUTOSTART WSZYSTKICH APLIKACJI
echo [10/10] Uruchamianie wszystkich aplikacji w tle...
timeout /t 2 >nul
cd /d "%INSTALL_DIR%"
call "Start_All.bat"
timeout /t 1 >nul

echo.
echo Wszystkie moduly powinny byc juz aktywne w tle/trayu.
echo Mozesz uzyc skrotu "CPU Manager v40 (START WSZYSTKO)" do ponownego uruchomienia.
echo.
pause
exit /b

:CopyFile
if exist "%~1" (
    copy /Y "%~1" "%INSTALL_DIR%\" >nul
    echo      - %~nx1 [OK]
) else (
    echo      - BLAD: Brak pliku %~nx1 w folderze instalatora!
)
goto :eof
