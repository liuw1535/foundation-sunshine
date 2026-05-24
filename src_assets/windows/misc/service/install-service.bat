@echo off
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0"
setlocal enabledelayedexpansion

rem Get sunshine root directory
for %%I in ("%~dp0\..") do set "ROOT_DIR=%%~fI"

set SERVICE_NAME=SunshineService
set "SERVICE_BIN=%ROOT_DIR%\tools\sunshinesvc.exe"
set "SERVICE_CONFIG_DIR=%LOCALAPPDATA%\LizardByte\Sunshine"
set "SERVICE_CONFIG_FILE=%SERVICE_CONFIG_DIR%\service_start_type.txt"

if not exist "%SERVICE_BIN%" (
    echo ERROR: Service binary not found: "%SERVICE_BIN%"
    exit /b 1
)

rem Set service to demand start. It will be changed to auto later if the user selected that option.
set SERVICE_START_TYPE=demand

rem Remove the legacy SunshineSvc service
net stop sunshinesvc
sc delete sunshinesvc

rem Check if SunshineService already exists.
rem Decision matrix:
rem   - not present                                     -> create
rem   - present AND binPath already matches new SERVICE_BIN -> config (in-place update)
rem   - present AND binPath points elsewhere (cross-dir reinstall, stale legacy
rem     record, "marked for deletion" stub) -> stop + delete + wait + create
rem
rem Old code unconditionally used `sc config` whenever sc qc returned 0. That
rem silently fails when the SCM record is stuck in "marked for deletion" after
rem a previous uninstall or when the old binPath still references a directory
rem that no longer exists. The Inno-side VerifyServiceInstalled() only checks
rem the final ImagePath substring, so a same-directory silent upgrade masked
rem this bug while interactive installs into a different directory raised
rem "无法安装或验证 Sunshine 服务".
rem
rem NOTE: avoid `goto` from inside parenthesized if-blocks (cmd parser quirk:
rem the goto exits the block and the matching `)` then errors out). Flat
rem control flow only.
set "SC_CMD="
sc qc %SERVICE_NAME% > nul 2>&1
if not %ERRORLEVEL%==0 goto :sc_decide_create

rem Service is present. Stop it (ignore errors: already-stopped, stop-pending,
rem marked-for-deletion all return non-zero but are fine).
net stop %SERVICE_NAME% >nul 2>&1

rem Compare existing binPath against the new SERVICE_BIN using the same
rem locale-safe substring match the post-install verification uses.
sc qc %SERVICE_NAME% | find /I "%SERVICE_BIN%" >nul
if not errorlevel 1 (
    set SC_CMD=config
    goto :sc_decide_done
)

echo Existing %SERVICE_NAME% binPath differs from "%SERVICE_BIN%"; recreating service.
sc delete %SERVICE_NAME% >nul 2>&1

rem Wait for SCM to actually release the record. `sc delete` is async: the
rem entry sticks around in "marked for deletion" state until every open
rem handle (services.msc, monitoring tools, our own sc qc above) is closed.
rem Poll up to ~10s.
set /a SC_DELETE_WAIT=0
:wait_sc_delete
sc qc %SERVICE_NAME% >nul 2>&1
if errorlevel 1 goto :sc_decide_create
if !SC_DELETE_WAIT! GEQ 10 (
    echo WARNING: %SERVICE_NAME% still present after sc delete; attempting create anyway.
    goto :sc_decide_create
)
set /a SC_DELETE_WAIT+=1
timeout /t 1 /nobreak >nul
goto :wait_sc_delete

:sc_decide_create
set SC_CMD=create

:sc_decide_done

rem Check if we have a saved start type from previous installation
if exist "%SERVICE_CONFIG_FILE%" (
    rem Debug output file content
    type "%SERVICE_CONFIG_FILE%"

    rem Read the saved start type
    for /f "usebackq delims=" %%a in ("%SERVICE_CONFIG_FILE%") do (
        set "SAVED_START_TYPE=%%a"
    )

    echo Raw saved start type: [!SAVED_START_TYPE!]

    rem Check start type
    if "!SAVED_START_TYPE!"=="2-delayed" (
        set SERVICE_START_TYPE=delayed-auto
    ) else if "!SAVED_START_TYPE!"=="2" (
        set SERVICE_START_TYPE=auto
    ) else if "!SAVED_START_TYPE!"=="3" (
        set SERVICE_START_TYPE=demand
    ) else if "!SAVED_START_TYPE!"=="4" (
        set SERVICE_START_TYPE=disabled
    )

    del "%SERVICE_CONFIG_FILE%"
)

echo Setting service start type set to: [!SERVICE_START_TYPE!]

rem Run the sc command to create/reconfigure the service
set "SC_START_TYPE=!SERVICE_START_TYPE!"
if /I "!SERVICE_START_TYPE!"=="delayed-auto" set "SC_START_TYPE=auto"

rem Retry sc create/config a few times. Common transient failures:
rem   1072 "service marked for deletion" - SCM hasn't fully released the old record
rem   1053 "service did not respond to start/control in a timely fashion"
rem   1056 "an instance of the service is already running"
rem A short backoff is enough to clear all of them in practice.
set /a SC_TRY=0
:sc_cmd_retry
sc !SC_CMD! %SERVICE_NAME% binPath= """%SERVICE_BIN%""" start= !SC_START_TYPE! DisplayName= "Sunshine Service"
if not errorlevel 1 goto :sc_cmd_ok
set /a SC_TRY+=1
if !SC_TRY! GEQ 5 (
    echo ERROR: Failed to !SC_CMD! %SERVICE_NAME% after !SC_TRY! attempts.
    exit /b 1
)
echo sc !SC_CMD! attempt !SC_TRY! failed; retrying in 1s...
timeout /t 1 /nobreak >nul
goto :sc_cmd_retry
:sc_cmd_ok

if /I "!SERVICE_START_TYPE!"=="delayed-auto" (
    sc config %SERVICE_NAME% start= delayed-auto
    if errorlevel 1 (
        echo ERROR: Failed to configure delayed auto-start for %SERVICE_NAME%.
        exit /b 1
    )
)

rem Verify the service was created/reconfigured AND that its binPath actually
rem points to the binary we just shipped. Substring match is enough here
rem because %SERVICE_BIN% is fully qualified and unique per install.
sc qc %SERVICE_NAME% | find /I "%SERVICE_BIN%" >nul
if errorlevel 1 (
    echo ERROR: %SERVICE_NAME% binPath does not match "%SERVICE_BIN%".
    exit /b 1
)

rem Set the description of the service. Description is metadata only and can
rem fail under SCM contention or AV interference; never abort install for it.
sc description %SERVICE_NAME% "Sunshine is a self-hosted game stream host for Moonlight."
if errorlevel 1 (
    echo WARNING: Failed to set %SERVICE_NAME% description; continuing.
)

if /I "!SERVICE_START_TYPE!"=="disabled" (
    echo %SERVICE_NAME% installed with disabled start type; skipping service start.
    exit /b 0
)

rem Start the new service. net start returns non-zero when the service is
rem already running (e.g. SCM auto-started it after sc config), so verify the
rem actual state via sc query before treating that as a failure.
net start %SERVICE_NAME%
if errorlevel 1 (
    sc query %SERVICE_NAME% | find /I "RUNNING" >nul
    if errorlevel 1 (
        echo ERROR: Failed to start %SERVICE_NAME%.
        exit /b 1
    )
)

rem Determine the Web UI port from config (default base port 47989 + 1 = 47990)
set /a WEB_PORT=47990
set "SUNSHINE_CONF=%ROOT_DIR%\config\sunshine.conf"
if exist "%SUNSHINE_CONF%" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%SUNSHINE_CONF%") do (
        set "KEY=%%a"
        set "VAL=%%b"
        rem Trim spaces from key
        for /f "tokens=* delims= " %%k in ("!KEY!") do set "KEY=%%k"
        if "!KEY!"=="port" (
            for /f "tokens=* delims= " %%v in ("!VAL!") do set "VAL=%%v"
            set /a WEB_PORT=!VAL!+1
        )
    )
)

rem Wait for Sunshine API to be ready
echo Waiting for Sunshine API on port !WEB_PORT!...
set /a WAIT_COUNT=0
set /a WAIT_MAX=15
:wait_loop
if !WAIT_COUNT! GEQ !WAIT_MAX! (
    echo Sunshine API did not become ready within %WAIT_MAX% seconds, continuing anyway...
    goto :wait_done
)
powershell -NoProfile -Command "try { $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', !WEB_PORT!); $c.Close(); exit 0 } catch { exit 1 }" >nul 2>&1
if !ERRORLEVEL!==0 (
    echo Sunshine API is ready on port !WEB_PORT!.
    goto :wait_done
)
set /a WAIT_COUNT+=1
timeout /t 1 /nobreak >nul
goto :wait_loop
:wait_done

exit /b 0
