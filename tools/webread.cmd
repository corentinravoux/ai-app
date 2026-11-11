@echo off
rem webread for Windows: runs the Python script next to this file.
where py >nul 2>nul && (py -3 "%~dp0webread" %*) || (python "%~dp0webread" %*)
