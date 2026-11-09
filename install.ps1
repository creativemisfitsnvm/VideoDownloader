# Misfit Downloader - one-time installer (bootstrap)
# Downloads the latest app from GitHub and runs the updater in install mode.
# Installs to %LOCALAPPDATA%\VideoDownloader - no admin rights needed.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$vdAppDir = Join-Path $env:LOCALAPPDATA 'VideoDownloader'
$vdTmp = Join-Path $env:TEMP ('misfit-downloader-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $vdAppDir, $vdTmp | Out-Null

Write-Host 'Installing Misfit Downloader...' -ForegroundColor Cyan
try {
    # Same source the updater uses (always the latest commit on main)
    $vdZip = Join-Path $vdTmp 'repo.zip'
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -OutFile $vdZip `
        -Uri 'https://codeload.github.com/creativemisfitsnvm/VideoDownloader/zip/refs/heads/main'
    Expand-Archive -LiteralPath $vdZip -DestinationPath $vdTmp
    $vdUpdater = Get-ChildItem -LiteralPath $vdTmp -Recurse -File -Filter 'update.ps1' | Select-Object -First 1
    Copy-Item -LiteralPath $vdUpdater.FullName -Destination (Join-Path $vdAppDir 'update.ps1') -Force
} finally {
    Remove-Item -LiteralPath $vdTmp -Recurse -Force -ErrorAction SilentlyContinue
}

& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vdAppDir 'update.ps1') -Install

if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Installation did not finish. Fix the problem above, then run Install.bat again.' -ForegroundColor Red
}
