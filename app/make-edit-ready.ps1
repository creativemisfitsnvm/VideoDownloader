# Converts downloaded videos into editor-friendly MP4 files
# (H.264 video + AAC audio, constant frame rate) for DaVinci Resolve / After Effects.
# Keeps the original resolution and frame rate.
#
# Two ways to use it:
#   - Command line: make-edit-ready.ps1 -ListFile files.txt -ToolsDir bin -DestDir out
#   - Dot-source it (no parameters) to get Get-EditReadyPlan for the app window
# Parameter names are deliberately unusual: dot-sourcing sets them in the caller's scope.
param(
    [string]$ListFile = '',                    # text file with one video path per line
    [Alias('BinDir')][string]$ToolsDir = '',   # folder containing ffmpeg.exe / ffprobe.exe
    [Alias('OutDir')][string]$DestDir = ''     # where the edit-ready files are written
)

# Quality settings: lower CRF = higher quality (16 is visually lossless for most footage)
$EditReadyCrf    = '16'
$EditReadyPreset = 'slow'
$EditReadyAudioBitrate = '320k'

function Get-MediaStream([string]$Ffprobe, [string]$Path, [string]$Selector) {
    $json = & $Ffprobe -v error -select_streams $Selector `
        -show_entries 'stream=codec_name,width,height,r_frame_rate,pix_fmt,color_transfer' `
        -of json -i $Path | Out-String
    $parsed = $json | ConvertFrom-Json
    if ($parsed.streams -and $parsed.streams.Count -gt 0) { return $parsed.streams[0] }
    return $null
}

function Get-MediaDuration([string]$Ffprobe, [string]$Path) {
    $d = & $Ffprobe -v error -show_entries 'format=duration' -of 'default=noprint_wrappers=1:nokey=1' -i $Path | Out-String
    $value = 0.0
    if ([double]::TryParse($d.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $value }
    return 0.0
}

# Works out the ffmpeg arguments for one file. Returns $null if the file has no video.
function Get-EditReadyPlan([string]$Src, [string]$Dst, [string]$Bin) {
    $ffprobe = Join-Path $Bin 'ffprobe.exe'
    $v = Get-MediaStream $ffprobe $Src 'v:0'
    $a = Get-MediaStream $ffprobe $Src 'a:0'
    if (-not $v) { return $null }

    $isHdr = @('smpte2084', 'arib-std-b67') -contains $v.color_transfer
    $canCopyVideo = ($v.codec_name -eq 'h264') -and ($v.pix_fmt -eq 'yuv420p') -and -not $isHdr

    $ffArgs = @('-y', '-i', $Src, '-map', '0:v:0')
    if ($canCopyVideo) {
        $ffArgs += @('-c:v', 'copy')
        $videoNote = 'H.264 already (copied, no quality loss)'
    } else {
        $ffArgs += @('-fps_mode', 'cfr')
        if ($v.r_frame_rate -match '^\d+/[1-9]\d*$') { $ffArgs += @('-r', $v.r_frame_rate) }
        if ($isHdr) {
            # HDR -> SDR tone map so colors don't look washed out in the editor
            $ffArgs += @('-vf', 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p')
            $videoNote = "$($v.codec_name) HDR -> H.264 SDR"
        } else {
            # Tag as Rec.709 (standard SDR) so editors interpret colors correctly
            $ffArgs += @('-vf', 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=yuv420p')
            $videoNote = "$($v.codec_name) -> H.264"
        }
        $ffArgs += @('-c:v', 'libx264', '-preset', $EditReadyPreset, '-crf', $EditReadyCrf, '-profile:v', 'high',
                     '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709')
    }

    if ($a) {
        $ffArgs += @('-map', '0:a:0')
        if ($a.codec_name -eq 'aac') {
            $ffArgs += @('-c:a', 'copy')
            $audioNote = 'AAC (copied)'
        } else {
            $ffArgs += @('-c:a', 'aac', '-b:a', $EditReadyAudioBitrate, '-ar', '48000')
            $audioNote = "$($a.codec_name) -> AAC $EditReadyAudioBitrate"
        }
    } else {
        $audioNote = 'none'
    }
    $ffArgs += @('-movflags', '+faststart', $Dst)

    return [pscustomobject]@{
        Args      = $ffArgs
        Summary   = ('{0}x{1} @ {2} fps | Video: {3} | Audio: {4}' -f $v.width, $v.height, $v.r_frame_rate, $videoNote, $audioNote)
        Duration  = (Get-MediaDuration $ffprobe $Src)
        CopyOnly  = $canCopyVideo
    }
}

# ---------- Command-line mode ----------
if (-not $ListFile) { return }

$ffmpeg = Join-Path $ToolsDir 'ffmpeg.exe'
if (-not (Test-Path -LiteralPath $ListFile)) {
    Write-Host 'No downloaded files to convert.'
    exit 0
}
if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir | Out-Null }

$files = Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -Unique
$failed = 0

foreach ($src in $files) {
    $src = $src.Trim()
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host "Skipping (file not found): $src" -ForegroundColor Yellow
        continue
    }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $dst  = Join-Path $DestDir ($name + '.mp4')
    $plan = Get-EditReadyPlan $src $dst $ToolsDir
    if (-not $plan) {
        Write-Host "Skipping (no video stream): $src" -ForegroundColor Yellow
        continue
    }

    Write-Host ''
    Write-Host "Making edit-ready copy: $name" -ForegroundColor Cyan
    Write-Host "  $($plan.Summary)"

    $ffArgs = @('-hide_banner', '-loglevel', 'error', '-stats') + $plan.Args
    & $ffmpeg @ffArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Saved: $dst" -ForegroundColor Green
    } else {
        Write-Host "  Conversion FAILED for: $src" -ForegroundColor Red
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
        $failed++
    }
}

exit $failed
