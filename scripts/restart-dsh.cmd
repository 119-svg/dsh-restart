@echo off
rem Restart DSH Desktop -- same effect as quitting from the tray and opening it again.
rem ASCII-only and CRLF on purpose: cmd.exe parses batch files with the OEM code page and
rem wants CRLF, so a UTF-8 file with non-ASCII comments and LF endings can fail to run at all.
rem Set DSH_RESTART_DRYRUN=1 before running to rehearse: it logs the plan and kills/starts nothing.
setlocal
set "EXTRA="
if /i "%DSH_RESTART_DRYRUN%"=="1" set "EXTRA=-DryRun"
echo [1/2] calling restart-dsh.ps1 %EXTRA%
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "restart-dsh.ps1" %EXTRA%
set "CODE=%ERRORLEVEL%"
popd
echo [2/2] launcher exit code = %CODE%
echo.
echo DSH will close and reopen in a moment.
echo Log: %USERPROFILE%\.dsh\dsh-restart.log
echo This window closes in 5 seconds.
timeout /t 5 /nobreak >nul 2>&1
endlocal
