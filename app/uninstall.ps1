# Removes Video Downloader (the app and its shortcuts).
# Your downloaded videos in Downloads\Video Downloader are NOT deleted.

$AppDir = Join-Path $env:LOCALAPPDATA 'VideoDownloader'
$Host.UI.RawUI.WindowTitle = 'Uninstall Video Downloader'

$answer = Read-Host 'Remove Video Downloader from this PC? Your downloaded videos are kept. (y/n)'
if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.'; exit 0 }

# Step out of the app folder so Windows lets us delete it
Set-Location $env:TEMP
[Environment]::CurrentDirectory = $env:TEMP
$desktop = [Environment]::GetFolderPath('Desktop')
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Video Downloader'
Remove-Item -LiteralPath (Join-Path $desktop 'Video Downloader.lnk') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $menu -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $AppDir -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $AppDir) {
    Write-Host "Some files could not be removed. Close Video Downloader and delete this folder: $AppDir" -ForegroundColor Yellow
} else {
    Write-Host 'Video Downloader was removed.' -ForegroundColor Green
}
Read-Host 'Press Enter to close'
