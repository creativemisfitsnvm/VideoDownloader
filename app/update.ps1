# Video Downloader - installer and updater
#
# Runs every time the app starts:
#   1. Pulls the latest scripts from GitHub (only files that changed are replaced)
#   2. Makes sure yt-dlp, ffmpeg and node are installed (downloads them if missing)
#   3. Updates yt-dlp once a day (sites change often)
#
# Exit codes: 0 = ok, 10 = scripts were updated (caller restarts), 1 = tools missing
param(
    [switch]$Install,        # first-time install: also creates shortcuts
    [string]$SourceDir = ''  # install/update from a local copy of the repo instead of GitHub
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo     = 'creativemisfitsnvm/VideoDownloader'
$Branch   = 'main'
$AppDir   = Join-Path $env:LOCALAPPDATA 'VideoDownloader'
$BinDir   = Join-Path $AppDir 'bin'
$StateDir = Join-Path $AppDir 'state'
$ScriptsUpdatedExitCode = 10

function Write-Info([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Warn([string]$msg) { Write-Host $msg -ForegroundColor Yellow }

function Get-File([string]$Url, [string]$OutFile, [switch]$Quiet) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        if ($Quiet) { $progress = '-s' } else { $progress = '-#' }
        & $curl -L --fail $progress --connect-timeout 20 -o $OutFile $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile -TimeoutSec 900
    }
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Checks a downloaded file against the publisher's checksum list
function Assert-Checksum([string]$File, [string]$SumsFile, [string]$Name) {
    $pattern = '[\s\*]' + [regex]::Escape($Name) + '$'
    $line = Get-Content -LiteralPath $SumsFile | Where-Object { $_.Trim() -match $pattern } | Select-Object -First 1
    if (-not $line) { throw "No published checksum found for $Name" }
    $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
    if ((Get-Sha256 $File) -ne $expected) { throw "Checksum mismatch for $Name (download corrupted or tampered with)" }
}

function New-TempDir {
    $dir = Join-Path $env:TEMP ('video-downloader-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    return $dir
}

# ---------- Scripts ----------

function Update-Scripts {
    $tmp = New-TempDir
    try {
        if ($SourceDir) {
            $src = Join-Path $SourceDir 'app'
        } else {
            $zip = Join-Path $tmp 'repo.zip'
            Get-File "https://codeload.github.com/$Repo/zip/refs/heads/$Branch" $zip -Quiet
            Expand-Archive -LiteralPath $zip -DestinationPath $tmp
            $root = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
            $src = Join-Path $root.FullName 'app'
        }
        if (-not (Test-Path -LiteralPath $src)) { throw "No 'app' folder found in $src" }

        $changed = @()
        foreach ($f in Get-ChildItem -LiteralPath $src -File) {
            $dst = Join-Path $AppDir $f.Name
            if (-not (Test-Path -LiteralPath $dst) -or (Get-Sha256 $f.FullName) -ne (Get-Sha256 $dst)) {
                Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
                $changed += $f.Name
            }
        }
        return ,$changed
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------- Tools ----------

function Install-YtDlp {
    Write-Info 'Downloading yt-dlp...'
    $tmp = New-TempDir
    try {
        $base = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download'
        Get-File "$base/yt-dlp.exe" (Join-Path $tmp 'yt-dlp.exe')
        Get-File "$base/SHA2-256SUMS" (Join-Path $tmp 'sums.txt') -Quiet
        Assert-Checksum (Join-Path $tmp 'yt-dlp.exe') (Join-Path $tmp 'sums.txt') 'yt-dlp.exe'
        Copy-Item -LiteralPath (Join-Path $tmp 'yt-dlp.exe') -Destination $BinDir -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-Ffmpeg {
    Write-Info 'Downloading ffmpeg (about 90 MB)...'
    $tmp = New-TempDir
    try {
        $name = 'ffmpeg-master-latest-win64-gpl-shared.zip'
        $base = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest'
        $zip = Join-Path $tmp $name
        Get-File "$base/$name" $zip
        Get-File "$base/checksums.sha256" (Join-Path $tmp 'sums.txt') -Quiet
        Assert-Checksum $zip (Join-Path $tmp 'sums.txt') $name
        Write-Info 'Extracting ffmpeg...'
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x')
        $bin = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Recurse -Directory -Filter 'bin' | Select-Object -First 1
        if (-not $bin) { throw 'ffmpeg download did not contain a bin folder' }
        Get-ChildItem -LiteralPath $bin.FullName -File |
            Where-Object { $_.Name -ne 'ffplay.exe' } |
            Copy-Item -Destination $BinDir -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-Node {
    Write-Info 'Downloading node (about 80 MB)...'
    $tmp = New-TempDir
    try {
        $lts = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60 |
            Where-Object { $_.lts } | Select-Object -First 1
        if (-not $lts) { throw 'Could not find the current Node.js LTS version' }
        $base = "https://nodejs.org/dist/$($lts.version)"
        Get-File "$base/win-x64/node.exe" (Join-Path $tmp 'node.exe')
        Get-File "$base/SHASUMS256.txt" (Join-Path $tmp 'sums.txt') -Quiet
        Assert-Checksum (Join-Path $tmp 'node.exe') (Join-Path $tmp 'sums.txt') 'win-x64/node.exe'
        Copy-Item -LiteralPath (Join-Path $tmp 'node.exe') -Destination $BinDir -Force
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-MissingTools {
    $ytdlp = Join-Path $BinDir 'yt-dlp.exe'
    if (-not (Test-Path -LiteralPath $ytdlp)) {
        Install-YtDlp
    } else {
        # Self-update yt-dlp at most once a day
        $stamp = Join-Path $StateDir 'yt-dlp-last-update.txt'
        $due = (-not (Test-Path -LiteralPath $stamp)) -or
               (((Get-Date) - (Get-Item -LiteralPath $stamp).LastWriteTime).TotalHours -ge 24)
        if ($due) {
            Write-Info 'Checking for yt-dlp updates...'
            & $ytdlp -U
            if ($LASTEXITCODE -eq 0) { Set-Content -LiteralPath $stamp -Value (Get-Date -Format o) }
            else { Write-Warn 'Could not update yt-dlp right now. Using the installed version.' }
        }
    }
    if (-not ((Test-Path -LiteralPath (Join-Path $BinDir 'ffmpeg.exe')) -and
              (Test-Path -LiteralPath (Join-Path $BinDir 'ffprobe.exe')))) {
        Install-Ffmpeg
    }
    if (-not (Test-Path -LiteralPath (Join-Path $BinDir 'node.exe'))) {
        Install-Node
    }
}

# ---------- Shortcuts ----------

function New-Shortcut([string]$Path, [string]$Script, [string]$Description) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($Path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $AppDir $Script) + '"'
    $lnk.WorkingDirectory = $AppDir
    $lnk.IconLocation = (Join-Path $BinDir 'yt-dlp.exe') + ',0'
    $lnk.Description = $Description
    $lnk.Save()
}

function New-Shortcuts {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Video Downloader'
    New-Item -ItemType Directory -Force -Path $menu | Out-Null
    New-Shortcut (Join-Path $desktop 'Video Downloader.lnk') 'VideoDownloader.ps1' 'Download videos and make edit-ready copies'
    New-Shortcut (Join-Path $menu 'Video Downloader.lnk') 'VideoDownloader.ps1' 'Download videos and make edit-ready copies'
    New-Shortcut (Join-Path $menu 'Uninstall Video Downloader.lnk') 'uninstall.ps1' 'Remove Video Downloader'
}

# ---------- Main ----------

New-Item -ItemType Directory -Force -Path $AppDir, $BinDir, $StateDir | Out-Null

$changed = @()
try {
    if ($Install) { Write-Info 'Installing Video Downloader scripts...' }
    $changed = Update-Scripts
    if ($changed.Count -gt 0 -and -not $Install) {
        Write-Host ('Updated to the latest version (' + ($changed -join ', ') + ')') -ForegroundColor Green
    }
} catch {
    if ($Install) {
        Write-Host "Install failed: could not download the app. $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    Write-Warn 'Could not check for updates (no internet?). Using the installed version.'
}

try {
    Install-MissingTools
} catch {
    Write-Host "Could not install the required tools: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check your internet connection and try again.' -ForegroundColor Red
    exit 1
}

if ($Install) {
    New-Shortcuts
    Write-Host ''
    Write-Host 'Video Downloader is installed.' -ForegroundColor Green
    Write-Host 'Open it from the "Video Downloader" shortcut on your Desktop or in the Start menu.'
    exit 0
}

if ($changed.Count -gt 0) { exit $ScriptsUpdatedExitCode }
exit 0
