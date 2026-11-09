# Removes Misfit Downloader (the app, its shortcuts and its Installed apps entry).
# Downloaded videos in Downloads\Misfit Downloader are NOT deleted.

$AppName = 'Misfit Downloader'
$AppDir  = Join-Path $env:LOCALAPPDATA 'VideoDownloader'
$BinDir  = Join-Path $AppDir 'bin'
Add-Type -AssemblyName PresentationFramework

$answer = [System.Windows.MessageBox]::Show(
    "Remove $AppName from this PC?`n`nYour downloaded videos are kept.", "Uninstall $AppName", 'YesNo', 'Question')
if ($answer -ne 'Yes') { exit 0 }

# Close the app and any tools it is running, so their files can be deleted
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*\VideoDownloader\VideoDownloader.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($BinDir, [StringComparison]::OrdinalIgnoreCase) } |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

# Step out of the app folder so Windows lets us delete it
Set-Location $env:TEMP
[Environment]::CurrentDirectory = $env:TEMP

$desktop = [Environment]::GetFolderPath('Desktop')
$programs = [Environment]::GetFolderPath('Programs')
foreach ($name in $AppName, 'Video Downloader') {
    Remove-Item -LiteralPath (Join-Path $desktop "$name.lnk") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $programs $name) -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MisfitDownloader' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $AppDir -Recurse -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $AppDir) {
    [void][System.Windows.MessageBox]::Show(
        "Some files could not be removed. Close $AppName and delete this folder:`n$AppDir", "Uninstall $AppName", 'OK', 'Warning')
} else {
    [void][System.Windows.MessageBox]::Show("$AppName was removed.", "Uninstall $AppName", 'OK', 'Information')
}
