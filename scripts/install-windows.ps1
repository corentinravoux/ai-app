# Build and install AI App on Windows for the current user.
#
#   powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install-windows.ps1 -NoBuild
#
# Installs the app into %LOCALAPPDATA%\Programs\ai-app, a Start-menu
# shortcut, and webread (the page reader local agents use) into
# %LOCALAPPDATA%\ai-app\bin. Needs Visual Studio's "Desktop development with
# C++" and Flutter. Built by CI, not yet run on a real Windows machine: see
# docs\next-steps-plan.md section C. ALCF is not available on Windows.
param([switch]$NoBuild)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $PSScriptRoot
$flutter = if ($env:FLUTTER) { $env:FLUTTER } else { 'flutter' }
$src = Join-Path $here 'build\windows\x64\runner\Release'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\ai-app'
$bin = Join-Path $env:LOCALAPPDATA 'ai-app\bin'

if (-not $NoBuild) {
    Push-Location $here
    try { & $flutter build windows --release; if ($LASTEXITCODE) { throw 'flutter build failed' } }
    finally { Pop-Location }
}
if (-not (Test-Path (Join-Path $src 'ai_app.exe'))) { throw "No build at $src" }

if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
Copy-Item -Recurse $src $dest

New-Item -ItemType Directory -Force $bin | Out-Null
Copy-Item (Join-Path $here 'tools\webread') $bin -Force
Copy-Item (Join-Path $here 'tools\webread.cmd') $bin -Force
Copy-Item (Join-Path $here 'tools\websearch') $bin -Force
Copy-Item (Join-Path $here 'tools\websearch.cmd') $bin -Force

$menu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $menu 'AI App.lnk'))
$link.TargetPath = Join-Path $dest 'ai_app.exe'
$link.WorkingDirectory = $env:USERPROFILE
$link.Save()

Write-Host "Installed to $dest. Start AI App from the Start menu."
