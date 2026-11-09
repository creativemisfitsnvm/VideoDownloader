# Video Downloader

Paste a video link, and you get two things:

- **The original** at the highest quality the site offers (via [yt-dlp](https://github.com/yt-dlp/yt-dlp)).
- **An edit-ready MP4** (H.264 + AAC, constant frame rate, same resolution and frame rate) that drops straight into DaVinci Resolve, After Effects or Premiere. You don't need Handbrake anymore.

It works with YouTube, Vimeo, X/Twitter, Instagram, TikTok, Facebook, Reddit and [about 1,800 other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).

## Install (one time)

1. Download **[Install.bat](https://raw.githubusercontent.com/creativemisfitsnvm/VideoDownloader/main/Install.bat)**. If it opens as text, right-click the link and choose **Save link as...**
2. Double-click `Install.bat`. If Windows shows "Windows protected your PC", click **More info**, then **Run anyway**.
3. Wait while it downloads its tools (about 200 MB, one time only).

Or paste this into PowerShell:

```powershell
irm https://raw.githubusercontent.com/creativemisfitsnvm/VideoDownloader/main/install.ps1 | iex
```

Installation doesn't need admin rights. The app goes in `%LOCALAPPDATA%\VideoDownloader`, and it adds a **Video Downloader** shortcut to your Desktop and Start menu.

## Use

1. Open **Video Downloader**.
2. Paste a link and press Enter.
3. Find your files in **Downloads\Video Downloader**:
   - `Downloads\Video Downloader\`: edit-ready MP4s, ready for your editor.
   - `Downloads\Video Downloader\Originals\`: untouched downloads. You can delete these if you don't need them.

Type `open` to open the folder. Press Enter on an empty line to quit.

## Updates are automatic

Every time the app opens, it:

- grabs the latest version of these scripts from this repo, and
- updates yt-dlp once a day, since sites change often.

If a tool goes missing, delete `%LOCALAPPDATA%\VideoDownloader\bin` and reopen the app. It downloads the tools again.

## Uninstall

Go to **Start menu > Video Downloader > Uninstall Video Downloader**. Your downloaded videos are kept.

## Notes

- **HDR videos** are tone-mapped to standard (SDR) color in the edit-ready copy so they don't look washed out.
- **Re-encoding takes time**, especially for long or 4K videos. Leave the window open until it says Done.
- **Private or login-only videos** (private Instagram, members-only content and similar) won't download.
- **DRM services** such as Netflix, Disney+ and Prime Video are not supported.

## For maintainers

```
Install.bat               one-time installer (runs install.ps1 from GitHub)
install.ps1               bootstrap: downloads app/update.ps1 and runs it with -Install
app/VideoDownloader.ps1   the app (shortcut target)
app/make-edit-ready.ps1   ffmpeg re-encode to H.264/AAC MP4
app/update.ps1            pulls app/* from this repo, installs/updates tools, makes shortcuts
app/uninstall.ps1         removes the app and shortcuts
```

- **Shipping a change:** edit files in `app/` and push to `main`. Everyone gets the change the next time they open the app.
- **Encoding settings:** `$Crf` and `$Preset` at the top of `app/make-edit-ready.ps1`.
- **Keep scripts ASCII-only.** Windows PowerShell 5.1 misreads non-ASCII characters in files without a BOM.
- **Tools** are downloaded from official sources and verified against their published SHA-256 checksums:
  - yt-dlp: [yt-dlp/yt-dlp releases](https://github.com/yt-dlp/yt-dlp/releases)
  - ffmpeg: [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds/releases), the win64 GPL shared build
  - node: [nodejs.org](https://nodejs.org/dist/), current LTS `node.exe`, used as yt-dlp's JavaScript runtime
