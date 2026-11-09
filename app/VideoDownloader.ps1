# Video Downloader
# Paste a link -> downloads the best quality available -> makes an edit-ready MP4
# (H.264 + AAC, same resolution and frame rate) for Resolve / After Effects.
param(
    [switch]$NoUpdate,   # skip the update check
    [switch]$Restarted   # set internally after a self-update, prevents restart loops
)

$AppDir = $PSScriptRoot
$BinDir = Join-Path $AppDir 'bin'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Host.UI.RawUI.WindowTitle = 'Video Downloader'

# ---- Update check (pulls latest scripts from GitHub, installs missing tools) ----
if (-not $NoUpdate) {
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppDir 'update.ps1')
    $code = $LASTEXITCODE
    if ($code -eq 10 -and -not $Restarted) {
        # Scripts changed: start again with the new version
        & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Restarted
        exit $LASTEXITCODE
    }
    if ($code -eq 1) {
        Read-Host 'Press Enter to close'
        exit 1
    }
}

# ---- Output folders: <your Downloads folder>\Video Downloader ----
try {
    $downloads = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
} catch { $downloads = $null }
if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
$OutDir  = Join-Path $downloads 'Video Downloader'
$OrigDir = Join-Path $OutDir 'Originals'
New-Item -ItemType Directory -Force -Path $OrigDir | Out-Null

$ListFile = Join-Path $env:TEMP 'video-downloader-files.txt'

Write-Host ''
Write-Host '=== Video Downloader ===' -ForegroundColor Cyan
Write-Host "Edit-ready files: $OutDir"
Write-Host "Originals:        $OrigDir"

while ($true) {
    Write-Host ''
    $url = Read-Host 'Paste link (type "open" to open the folder, or press Enter to quit)'
    if ([string]::IsNullOrWhiteSpace($url)) { break }
    $url = $url.Trim().Trim('"').Trim()
    if ($url -eq 'open') { Start-Process explorer.exe $OutDir; continue }

    Remove-Item -LiteralPath $ListFile -Force -ErrorAction SilentlyContinue
    Write-Host ''

    & (Join-Path $BinDir 'yt-dlp.exe') -f 'bv*+ba/b' --merge-output-format mp4 `
        --ffmpeg-location $BinDir --js-runtimes ('node:' + (Join-Path $BinDir 'node.exe')) `
        --no-continue -N 4 -P $OrigDir --print-to-file 'after_move:filepath' $ListFile $url

    # Re-encode to H.264/AAC MP4 at the same resolution and frame rate
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $AppDir 'make-edit-ready.ps1') `
        -ListFile $ListFile -BinDir $BinDir -OutDir $OutDir

    Write-Host ''
    Write-Host "Done. Edit-ready files are in: $OutDir" -ForegroundColor Green
}
