@echo off
setlocal

cd /d "%~dp0"

if /I "%~1"=="help" goto :help
if /I "%~1"=="--help" goto :help
if /I "%~1"=="/?" goto :help

set "PY_EXE="
set "PY_FLAGS="

where py >nul 2>nul
if not errorlevel 1 (
    set "PY_EXE=py"
    set "PY_FLAGS=-3"
) else (
    where python >nul 2>nul
    if not errorlevel 1 (
        set "PY_EXE=python"
    ) else (
        where python3 >nul 2>nul
        if not errorlevel 1 (
            set "PY_EXE=python3"
        )
    )
)

if "%PY_EXE%"=="" (
    call set "ABRR_TIME=%%time: =0%%"
    call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Python was not found. Install Python 3 first.
    call set "ABRR_TIME=%%time: =0%%"
    call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Download: https://www.python.org/downloads/windows/
    pause
    exit /b 1
)

%PY_EXE% %PY_FLAGS% -c "import cloudscraper" >nul 2>nul
if errorlevel 1 (
    call set "ABRR_TIME=%%time: =0%%"
    call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Installing missing dependency: cloudscraper
    %PY_EXE% %PY_FLAGS% -m pip install --user cloudscraper
    if errorlevel 1 (
        call set "ABRR_TIME=%%time: =0%%"
        call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Failed to install cloudscraper.
        call set "ABRR_TIME=%%time: =0%%"
        call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Try: %PY_EXE% %PY_FLAGS% -m pip install --user cloudscraper
        pause
        exit /b 1
    )
)

if "%~1"=="" (
    call set "ABRR_TIME=%%time: =0%%"
    call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Starting continuous poller ^(60s interval^)...
    call set "ABRR_TIME=%%time: =0%%"
    call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Output: AutoBand_RealmRank.csv
    %PY_EXE% %PY_FLAGS% autoband_realmrank_poller.py --poll-seconds 60 --output-csv AutoBand_RealmRank.csv
) else (
    %PY_EXE% %PY_FLAGS% autoband_realmrank_poller.py %*
)

set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    call set "ABRR_TIME=%%time: =0%%"
    call echo [%%date%% %%ABRR_TIME:~0,8%%] [ABRR] Poller exited with error code %EXIT_CODE%.
    pause
)
exit /b %EXIT_CODE%

:help
echo AutoBand Realm Rank Windows poller launcher
echo.
echo Usage:
echo   run_autoband_realmrank_poller_windows.cmd
echo     Starts continuous polling every 60 seconds.
echo.
echo   run_autoband_realmrank_poller_windows.cmd --once
echo     Runs one poll and exits.
echo.
echo   run_autoband_realmrank_poller_windows.cmd --once --output-csv "C:\Path\AutoBand_RealmRank.csv"
echo     One-shot poll to a specific output file.
echo.
echo Any arguments are passed through to autoband_realmrank_poller.py.
exit /b 0
