# Video Downloader - one-time installer (bootstrap)
# Downloads the updater from GitHub and runs it in install mode.
# Installs to %LOCALAPPDATA%\VideoDownloader - no admin rights needed.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$vdAppDir = Join-Path $env:LOCALAPPDATA 'VideoDownloader'
$vdUpdater = Join-Path $vdAppDir 'update.ps1'
New-Item -ItemType Directory -Force -Path $vdAppDir | Out-Null

Write-Host 'Installing Video Downloader...' -ForegroundColor Cyan
Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 `
    -Uri 'https://raw.githubusercontent.com/creativemisfitsnvm/VideoDownloader/main/app/update.ps1' `
    -OutFile $vdUpdater

& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -NoProfile -ExecutionPolicy Bypass -File $vdUpdater -Install
