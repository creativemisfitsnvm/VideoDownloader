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

# ---------- Quality / speed settings ----------
$EditReadyUseGpu       = $true     # use the graphics card when it can help ($false = always CPU)
$EditReadyNvencCq      = '20'      # NVIDIA encoder quality: lower = better. 20 measured slightly above x264 CRF 16
$EditReadyCrf          = '16'      # CPU (x264) quality: lower = better. 16 is visually lossless for most footage
$EditReadyPreset       = 'medium'  # CPU (x264) speed: 'medium' matched 'slow' quality in testing and is faster
$EditReadyAudioBitrate = '320k'

$script:EditReadyGpu = $null       # what the graphics card can do; detected once per run

function Get-NvencArgs {
    @('-c:v', 'h264_nvenc', '-preset', 'p7', '-tune', 'hq', '-rc', 'vbr', '-cq', $EditReadyNvencCq, '-b:v', '0',
      '-maxrate', '250M', '-bufsize', '500M', '-spatial-aq', '1', '-temporal-aq', '1', '-bf', '3', '-b_ref_mode', 'middle',
      '-profile:v', 'high')
}
function Get-X264Args { @('-c:v', 'libx264', '-preset', $EditReadyPreset, '-crf', $EditReadyCrf, '-profile:v', 'high') }

function Test-FfmpegWorks([string]$Ffmpeg, [string[]]$Argv) {
    try { $null = & $Ffmpeg @Argv 2>&1; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# Checks (once) whether this PC can encode on an NVIDIA card and tone-map HDR on the GPU (Vulkan)
function Get-EditReadyGpu([string]$Bin) {
    if ($null -ne $script:EditReadyGpu) { return $script:EditReadyGpu }
    $caps = [pscustomobject]@{ Nvenc = $false; Vulkan = $false }
    if ($EditReadyUseGpu) {
        $ff = Join-Path $Bin 'ffmpeg.exe'
        $caps.Nvenc = Test-FfmpegWorks $ff (@('-hide_banner', '-loglevel', 'quiet', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30:duration=0.2',
                                             '-pix_fmt', 'yuv420p') + (Get-NvencArgs) + @('-f', 'null', '-'))
        $caps.Vulkan = Test-FfmpegWorks $ff @('-hide_banner', '-loglevel', 'quiet', '-init_hw_device', 'vulkan', '-f', 'lavfi',
                                             '-i', 'testsrc2=size=1280x720:rate=30:duration=0.2', '-vf', 'libplacebo=format=yuv420p', '-f', 'null', '-')
    }
    $script:EditReadyGpu = $caps
    return $caps
}

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
# GPU plans carry a CPU-only .Fallback plan to retry with if the GPU run fails.
function Get-EditReadyPlan([string]$Src, [string]$Dst, [string]$Bin, [switch]$CpuOnly) {
    $ffprobe = Join-Path $Bin 'ffprobe.exe'
    $v = Get-MediaStream $ffprobe $Src 'v:0'
    $a = Get-MediaStream $ffprobe $Src 'a:0'
    if (-not $v) { return $null }

    $isHdr = @('smpte2084', 'arib-std-b67') -contains $v.color_transfer
    $canCopyVideo = ($v.codec_name -eq 'h264') -and ($v.pix_fmt -eq 'yuv420p') -and -not $isHdr

    $useNvenc = $false; $useVulkan = $false
    if (-not $CpuOnly -and -not $canCopyVideo) {
        $gpu = Get-EditReadyGpu $Bin
        # NVIDIA's H.264 encoder tops out at 4096 pixels per side (8K stays on the CPU)
        $useNvenc = $gpu.Nvenc -and ([int]$v.width -le 4096) -and ([int]$v.height -le 4096)
        $useVulkan = $gpu.Vulkan -and $isHdr
    }

    $inputArgs = @()
    $videoArgs = @()
    if ($canCopyVideo) {
        $videoArgs = @('-c:v', 'copy')
        $videoNote = 'H.264 already (copied, no quality loss)'
    } else {
        $videoArgs += @('-fps_mode', 'cfr')
        if ($v.r_frame_rate -match '^\d+/[1-9]\d*$') { $videoArgs += @('-r', $v.r_frame_rate) }
        if ($isHdr -and $useVulkan) {
            # HDR -> SDR tone map on the graphics card (decoding there too when it can)
            $inputArgs = @('-init_hw_device', 'vulkan=vk', '-hwaccel', 'vulkan', '-hwaccel_device', 'vk', '-hwaccel_output_format', 'vulkan')
            $videoArgs += @('-vf', 'libplacebo=tonemapping=hable:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=yuv420p')
        } elseif ($isHdr) {
            # HDR -> SDR tone map on the CPU so colors don't look washed out in the editor
            $videoArgs += @('-vf', 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p')
        } else {
            # Tag as Rec.709 (standard SDR) so editors interpret colors correctly
            $videoArgs += @('-vf', 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=yuv420p')
        }
        if ($useNvenc) { $videoArgs += Get-NvencArgs; $where = 'NVIDIA GPU' } else { $videoArgs += Get-X264Args; $where = "CPU ($EditReadyPreset)" }
        $videoArgs += @('-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709')
        if ($isHdr) {
            $tm = 'CPU'; if ($useVulkan) { $tm = 'GPU' }
            $videoNote = "$($v.codec_name) HDR -> H.264 SDR (encode: $where, tone-map: $tm)"
        } else {
            $videoNote = "$($v.codec_name) -> H.264 (encode: $where)"
        }
    }

    $audioArgs = @()
    if ($a) {
        $audioArgs += @('-map', '0:a:0')
        if ($a.codec_name -eq 'aac') {
            $audioArgs += @('-c:a', 'copy')
            $audioNote = 'AAC (copied)'
        } else {
            $audioArgs += @('-c:a', 'aac', '-b:a', $EditReadyAudioBitrate, '-ar', '48000')
            $audioNote = "$($a.codec_name) -> AAC $EditReadyAudioBitrate"
        }
    } else {
        $audioNote = 'none'
    }

    $ffArgs = @('-y') + $inputArgs + @('-i', $Src, '-map', '0:v:0') + $videoArgs + $audioArgs + @('-movflags', '+faststart', $Dst)
    $fallback = $null
    if ($useNvenc -or $useVulkan) { $fallback = Get-EditReadyPlan $Src $Dst $Bin -CpuOnly }

    return [pscustomobject]@{
        Args      = $ffArgs
        Summary   = ('{0}x{1} @ {2} fps | Video: {3} | Audio: {4}' -f $v.width, $v.height, $v.r_frame_rate, $videoNote, $audioNote)
        Duration  = (Get-MediaDuration $ffprobe $Src)
        CopyOnly  = $canCopyVideo
        Fallback  = $fallback
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
    if ($LASTEXITCODE -ne 0 -and $plan.Fallback) {
        Write-Host '  Graphics card conversion failed, retrying on the CPU...' -ForegroundColor Yellow
        Write-Host "  $($plan.Fallback.Summary)"
        $ffArgs = @('-hide_banner', '-loglevel', 'error', '-stats') + $plan.Fallback.Args
        & $ffmpeg @ffArgs
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Saved: $dst" -ForegroundColor Green
    } else {
        Write-Host "  Conversion FAILED for: $src" -ForegroundColor Red
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }
        $failed++
    }
}

exit $failed
