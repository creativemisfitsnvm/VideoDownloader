# Misfit Downloader - installer and updater
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
$AppName  = 'Misfit Downloader'
$AppId    = 'CreativeMisfits.MisfitDownloader'
$Publisher = 'Creative Misfits'
$ShortcutsVersion = '2'   # bump to re-create shortcuts on every PC

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
        # Assign first: Windows PowerShell 5.1 passes a JSON array down the pipeline as ONE object
        $releases = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 60
        $lts = $releases | Where-Object { $_.lts } | Select-Object -First 1
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

# Tags a shortcut with the app's taskbar ID so the taskbar shows the app icon and pins correctly
$shortcutIdSource = @"
using System;
using System.Runtime.InteropServices;
namespace MisfitDl {
  [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    void GetCount(out uint count);
    void GetAt(uint index, out PropertyKey key);
    void GetValue(ref PropertyKey key, out PropVariant value);
    void SetValue(ref PropertyKey key, ref PropVariant value);
    void Commit();
  }
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  public struct PropertyKey { public Guid fmtid; public uint pid; }
  [StructLayout(LayoutKind.Explicit)]
  public struct PropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(16)] public IntPtr pad; }
  public static class ShortcutId {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHGetPropertyStoreFromParsingName(string path, IntPtr bindCtx, int flags, ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    public static void Set(string lnkPath, string appId) {
      Guid iid = typeof(IPropertyStore).GUID;
      IPropertyStore store;
      SHGetPropertyStoreFromParsingName(lnkPath, IntPtr.Zero, 2, ref iid, out store);
      PropertyKey key = new PropertyKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
      PropVariant value = new PropVariant { vt = 31, p = Marshal.StringToCoTaskMemUni(appId) };
      try { store.SetValue(ref key, ref value); store.Commit(); }
      finally { Marshal.FreeCoTaskMem(value.p); Marshal.ReleaseComObject(store); }
    }
  }
}
"@

function New-Shortcut([string]$Path, [string]$Script, [string]$Description, [switch]$App) {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($Path)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $AppDir $Script) + '"'
    $lnk.WorkingDirectory = $AppDir
    $lnk.IconLocation = (Join-Path $AppDir 'logo.ico') + ',0'
    $lnk.Description = $Description
    $lnk.WindowStyle = 7   # start minimized: no console flash
    $lnk.Save()
    if ($App) {
        try {
            if (-not ('MisfitDl.ShortcutId' -as [type])) { Add-Type -TypeDefinition $shortcutIdSource }
            [MisfitDl.ShortcutId]::Set($Path, $AppId)
        } catch { Write-Warn "Could not set taskbar ID on shortcut: $($_.Exception.Message)" }
    }
}

function Remove-LegacyShortcuts {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $programs = [Environment]::GetFolderPath('Programs')
    Remove-Item -LiteralPath (Join-Path $desktop 'Video Downloader.lnk') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $programs 'Video Downloader') -Recurse -Force -ErrorAction SilentlyContinue
}

function New-Shortcuts {
    Remove-LegacyShortcuts
    $desktop = [Environment]::GetFolderPath('Desktop')
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) $AppName
    New-Item -ItemType Directory -Force -Path $menu | Out-Null
    $desc = 'Download videos and make edit-ready copies'
    New-Shortcut (Join-Path $desktop "$AppName.lnk") 'VideoDownloader.ps1' $desc -App
    New-Shortcut (Join-Path $menu "$AppName.lnk") 'VideoDownloader.ps1' $desc -App
    New-Shortcut (Join-Path $menu "Uninstall $AppName.lnk") 'uninstall.ps1' "Remove $AppName"
    Set-Content -LiteralPath (Join-Path $StateDir 'shortcuts-version.txt') -Value $ShortcutsVersion
}

# ---------- Installed apps (Settings > Apps) ----------

function Register-App {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MisfitDownloader'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    $version = '1.0.0'
    $vf = Join-Path $AppDir 'version.txt'
    if (Test-Path -LiteralPath $vf) { $version = (Get-Content -LiteralPath $vf -TotalCount 1).Trim() }
    $sizeKb = [int](((Get-ChildItem -LiteralPath $AppDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1KB)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $values = @{
        DisplayName     = $AppName
        DisplayVersion  = $version
        DisplayIcon     = (Join-Path $AppDir 'logo.ico')
        Publisher       = $Publisher
        InstallLocation = $AppDir
        URLInfoAbout    = "https://github.com/$Repo"
        UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $AppDir 'uninstall.ps1')`""
    }
    foreach ($k in $values.Keys) { Set-ItemProperty -Path $key -Name $k -Value $values[$k] }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $key -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null
    if (-not (Get-ItemProperty -Path $key -Name 'InstallDate' -ErrorAction SilentlyContinue)) {
        Set-ItemProperty -Path $key -Name 'InstallDate' -Value (Get-Date -Format 'yyyyMMdd')
    }
}

# ---------- Main ----------

New-Item -ItemType Directory -Force -Path $AppDir, $BinDir, $StateDir | Out-Null

$changed = @()
try {
    if ($Install) { Write-Info "Installing $AppName..." }
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

# Shortcuts: always on install; otherwise once whenever the shortcut design changes
$shortcutStamp = Join-Path $StateDir 'shortcuts-version.txt'
$currentShortcuts = ''
if (Test-Path -LiteralPath $shortcutStamp) { $currentShortcuts = (Get-Content -LiteralPath $shortcutStamp -TotalCount 1).Trim() }
if ($Install -or $currentShortcuts -ne $ShortcutsVersion) {
    try { New-Shortcuts } catch { Write-Warn "Could not create shortcuts: $($_.Exception.Message)" }
}
try { Register-App } catch { Write-Warn "Could not add $AppName to Installed apps: $($_.Exception.Message)" }

if ($Install) {
    Write-Host ''
    Write-Host "$AppName is installed." -ForegroundColor Green
    Write-Host "Open it from the `"$AppName`" shortcut on your Desktop or in the Start menu."
    exit 0
}

if ($changed.Count -gt 0) { exit $ScriptsUpdatedExitCode }
exit 0