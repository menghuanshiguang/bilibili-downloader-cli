@echo off
rem =====================================================================
rem bilidown - Bilibili audio/video downloader CLI (Windows entry)
rem Auto-locates Git Bash / WSL and invokes bin/bilidown (bash impl).
rem Usage is identical to bilidown, e.g.:
rem   bilidown dl "BV1GJ411x7h7" audio
rem   bilidown dl "BV1GJ411x7h7" video out mp4 1080
rem   bilidown search "keyword"
rem =====================================================================
setlocal
set "BILIDOWN_DIR=%~dp0"

rem 1) bash on PATH
where bash >nul 2>nul
if %errorlevel%==0 (
  pushd "%BILIDOWN_DIR%.."
  bash "bin/bilidown" %*
  set "RC=%errorlevel%"
  popd
  exit /b %RC%
)

rem 2) common Git Bash install paths
for %%G in ("D:\Program Files\Git\bin\bash.exe" "C:\Program Files\Git\bin\bash.exe" "%LOCALAPPDATA%\Programs\Git\bin\bash.exe") do (
  if exist %%G (
    pushd "%BILIDOWN_DIR%.."
    "%%~G" "bin/bilidown" %*
    set "RC=%errorlevel%"
    popd
    exit /b %RC%
  )
)

rem 3) WSL
where wsl >nul 2>nul
if %errorlevel%==0 (
  pushd "%BILIDOWN_DIR%.."
  wsl bash "bin/bilidown" %*
  set "RC=%errorlevel%"
  popd
  exit /b %RC%
)

echo [bilidown] bash not found. Install Git for Windows (https://git-scm.com/download/win) or WSL, then retry. 1>&2
exit /b 1
