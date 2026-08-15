@echo off
rem =====================================================================
rem bilidown - Bilibili audio/video downloader CLI (Windows entry)
rem Invokes the cross-platform Python implementation bin/bilidown.py.
rem Requires: Python 3.8+ on PATH. ffmpeg needed for audio/video modes.
rem Usage is identical to bilidown, e.g.:
rem   bilidown dl "BV1GJ411x7h7" audio
rem   bilidown dl "BV1GJ411x7h7" video out mp4 1080
rem   bilidown search "keyword"
rem =====================================================================
setlocal
set "BILIDOWN_SCRIPT=%~dp0bilidown.py"

where python >nul 2>nul
if %errorlevel%==0 (
  python "%BILIDOWN_SCRIPT%" %*
  exit /b %errorlevel%
)

where python3 >nul 2>nul
if %errorlevel%==0 (
  python3 "%BILIDOWN_SCRIPT%" %*
  exit /b %errorlevel%
)

echo [bilidown] python not found. Install Python 3.8+ from https://www.python.org/downloads/ (check "Add to PATH"), then retry. 1>&2
exit /b 1
