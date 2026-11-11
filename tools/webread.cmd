@echo off
rem webread for Windows: runs the Python script next to this file, once.
where py >nul 2>nul
if errorlevel 1 (
  python "%~dp0webread" %*
) else (
  py -3 "%~dp0webread" %*
)
exit /b %errorlevel%
