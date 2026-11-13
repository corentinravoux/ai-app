@echo off
rem websearch for Windows: runs the Python script next to this file, once.
where py >nul 2>nul
if errorlevel 1 (
  python "%~dp0websearch" %*
) else (
  py -3 "%~dp0websearch" %*
)
exit /b %errorlevel%
