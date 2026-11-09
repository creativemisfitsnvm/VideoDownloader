@echo off
title Install Misfit Downloader
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm 'https://raw.githubusercontent.com/creativemisfitsnvm/VideoDownloader/main/install.ps1' | iex"
echo.
pause
