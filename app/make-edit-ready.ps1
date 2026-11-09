# Converts downloaded videos into editor-friendly MP4 files
# (H.264 video + AAC audio, constant frame rate) for DaVinci Resolve / After Effects.
# Keeps the original resolution and frame rate.
param(
    [Parameter(Mandatory = $true)][string]$ListFile,  # text file with one video path per line
    [Parameter(Mandatory = $true)][string]$BinDir,    # folder containing ffmpeg.exe / ffprobe.exe
    [Parameter(Mandatory = $true)][string]$OutDir     # where the edit-ready files are written
)

$ErrorActionPreference = 'Stop'
$ffmpeg  = Join-Path $BinDir 'ffmpeg.exe'
$ffprobe = Join-Path $BinDir 'ffprobe.exe'

# Quality settings: lower CRF = higher quality (16 is visually lossless for most footage)
$Crf    = '16'
$Preset = 'slow'
$AudioBitrate = '320k'

function Get-StreamInfo([string]$path, [string]$selector) {
    $json = & $ffprobe -v error -select_streams $selector `
        -show_entries 'stream=codec_name,width,height,r_frame_rate,pix_fmt,color_transfer' `
        -of json -i $path | Out-String
    $parsed = $json | ConvertFrom-Json
    if ($parsed.streams -and $parsed.streams.Count -gt 0) { return $parsed.streams[0] }
    return $null
}

if (-not (Test-Path -LiteralPath $ListFile)) {
    Write-Host 'No downloaded files to convert.'
    exit 0
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

$files = Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -Unique
$failed = 0

foreach ($src in $files) {
    $src = $src.Trim()
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host "Skipping (file not found): $src" -ForegroundColor Yellow
        continue
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $dst  = Join-Path $OutDir ($name + '.mp4')

    $v = Get-StreamInfo $src 'v:0'
    $a = Get-StreamInfo $src 'a:0'
    if (-not $v) {
        Write-Host "Skipping (no video stream): $src" -ForegroundColor Yellow
        continue
    }

    $isHdr = @('smpte2084', 'arib-std-b67') -contains $v.color_transfer
    $canCopyVideo = ($v.codec_name -eq 'h264') -and ($v.pix_fmt -eq 'yuv420p') -and -not $isHdr

    $ffArgs = @('-hide_banner', '-loglevel', 'error', '-stats', '-y', '-i', $src, '-map', '0:v:0')

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
        $ffArgs += @('-c:v', 'libx264', '-preset', $Preset, '-crf', $Crf, '-profile:v', 'high',
                   '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709')
    }

    if ($a) {
        $ffArgs += @('-map', '0:a:0')
        if ($a.codec_name -eq 'aac') {
            $ffArgs += @('-c:a', 'copy')
            $audioNote = 'AAC (copied)'
        } else {
            $ffArgs += @('-c:a', 'aac', '-b:a', $AudioBitrate, '-ar', '48000')
            $audioNote = "$($a.codec_name) -> AAC $AudioBitrate"
        }
    } else {
        $audioNote = 'none'
    }

    $ffArgs += @('-movflags', '+faststart', $dst)

    Write-Host ''
    Write-Host "Making edit-ready copy: $name" -ForegroundColor Cyan
    Write-Host ("  {0}x{1} @ {2} fps | Video: {3} | Audio: {4}" -f $v.width, $v.height, $v.r_frame_rate, $videoNote, $audioNote)

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