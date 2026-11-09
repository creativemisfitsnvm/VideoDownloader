# Misfit Downloader - desktop app
# Paste links -> downloads the best quality available -> makes an edit-ready MP4
# (H.264 + AAC, same resolution and frame rate) for Resolve / After Effects.
param(
    [switch]$NoUpdate,          # skip the update check
    [switch]$Restarted,         # set after a self-update, prevents restart loops
    [string]$Screenshot = ''    # maintainers: render the window to this PNG and exit
)

$ErrorActionPreference = 'Stop'
$AppName  = 'Misfit Downloader'
$AppId    = 'CreativeMisfits.MisfitDownloader'
$AppDir   = $PSScriptRoot
$BinDir   = Join-Path $AppDir 'bin'
$StateDir = Join-Path $AppDir 'state'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Hide the console window and give the app its own taskbar identity (so it shows the app icon)
try {
    Add-Type -Namespace MisfitDl -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);
'@
    if (-not $Screenshot) {
        [void][MisfitDl.Native]::ShowWindow([MisfitDl.Native]::GetConsoleWindow(), 0)
        [void][MisfitDl.Native]::SetCurrentProcessExplicitAppUserModelID($AppId)
    }
} catch { }

$Version = '?'
$versionFile = Join-Path $AppDir 'version.txt'
if (Test-Path -LiteralPath $versionFile) { $Version = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }

# ---------- Output folders ----------
try {
    $downloads = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
} catch { $downloads = $null }
if (-not $downloads) { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
$OutDir = Join-Path $downloads $AppName
# Earlier versions saved to "Video Downloader": rename that folder so existing files move along
$legacyOut = Join-Path $downloads 'Video Downloader'
if ((Test-Path -LiteralPath $legacyOut) -and -not (Test-Path -LiteralPath $OutDir) -and -not $Screenshot) {
    try { Rename-Item -LiteralPath $legacyOut -NewName $AppName } catch { $OutDir = $legacyOut }
}
$OrigDir = Join-Path $OutDir 'Originals'

# ---------- Settings ----------
$SettingsFile = Join-Path $StateDir 'settings.json'
$Settings = [pscustomobject]@{ EditReady = $true; KeepOriginal = $true }
try {
    if (Test-Path -LiteralPath $SettingsFile) {
        $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $saved.EditReady) { $Settings.EditReady = [bool]$saved.EditReady }
        if ($null -ne $saved.KeepOriginal) { $Settings.KeepOriginal = [bool]$saved.KeepOriginal }
    }
} catch { }

# ---------- Window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Misfit Downloader" Width="760" Height="760" MinWidth="620" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#F3F3F1"
        FontFamily="Segoe UI" FontSize="13" Foreground="#161616" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#161616"/>
      <Setter Property="BorderBrush" Value="#CFCFCB"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.65"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#111111"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#111111"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,9"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="BorderBrush" Value="#E2E2DE"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,0,22,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
  </Window.Resources>

  <Grid Margin="22,16,22,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Grid Grid.Row="0" Margin="0,0,0,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Image x:Name="LogoImage" Height="92" Margin="0,0,22,0" RenderOptions.BitmapScalingMode="HighQuality"/>
      <StackPanel Grid.Column="1" VerticalAlignment="Center">
        <TextBlock Text="Paste links. Get the best quality, plus an edit-ready MP4." FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
        <TextBlock Text="Edit-ready copies are H.264 + AAC at the original resolution and frame rate, ready for Resolve, After Effects and Premiere."
                   Foreground="#6B6B66" TextWrapping="Wrap" Margin="0,4,0,0"/>
      </StackPanel>
    </Grid>

    <!-- Update banner -->
    <Border x:Name="Banner" Grid.Row="1" Visibility="Collapsed" Background="#FFF4E5" BorderBrush="#F2C98B" BorderThickness="1"
            CornerRadius="8" Padding="12,9" Margin="0,0,0,14">
      <TextBlock x:Name="BannerText" TextWrapping="Wrap"/>
    </Border>

    <!-- Links -->
    <Border Grid.Row="2" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="Video links" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <Grid>
          <TextBox x:Name="UrlBox" Height="96" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto" Padding="8,6" BorderBrush="#CFCFCB" FontSize="13"/>
          <TextBlock x:Name="UrlHint" IsHitTestVisible="False" Foreground="#9A9A94" Margin="12,8,0,0" TextWrapping="Wrap"
                     Text="Paste one or more links (one per line). YouTube, Vimeo, Instagram, TikTok, X and many more."/>
        </Grid>
        <WrapPanel Margin="0,12,0,0">
          <CheckBox x:Name="EditReadyChk" Content="Make edit-ready MP4 (H.264 + AAC)"/>
          <CheckBox x:Name="KeepOrigChk" Content="Keep original download"/>
        </WrapPanel>
        <DockPanel Margin="0,14,0,0" LastChildFill="False">
          <Button x:Name="PasteBtn" Style="{StaticResource Btn}" Content="Paste" Margin="0,0,8,0" DockPanel.Dock="Left"/>
          <Button x:Name="ClearBtn" Style="{StaticResource Btn}" Content="Clear" DockPanel.Dock="Left"/>
          <Button x:Name="DownloadBtn" Style="{StaticResource PrimaryBtn}" Content="Download" DockPanel.Dock="Right" IsDefault="False"/>
        </DockPanel>
      </StackPanel>
    </Border>

    <!-- Progress -->
    <Border x:Name="ProgressCard" Grid.Row="3" Style="{StaticResource Card}">
      <StackPanel>
        <DockPanel LastChildFill="True">
          <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel" DockPanel.Dock="Right" Padding="14,5" IsEnabled="False"/>
          <StackPanel>
            <TextBlock x:Name="ItemText" Foreground="#6B6B66" FontSize="12" Text="Ready"/>
            <TextBlock x:Name="TitleText" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis" Margin="0,2,10,0"
                       Text="Paste a link and press Download."/>
          </StackPanel>
        </DockPanel>
        <ProgressBar x:Name="Bar" Height="8" Margin="0,12,0,8" Minimum="0" Maximum="100" Value="0"
                     Foreground="#111111" Background="#E9E9E5" BorderThickness="0"/>
        <TextBlock x:Name="StatusText" Foreground="#4A4A46" TextTrimming="CharacterEllipsis" Text=" "/>
      </StackPanel>
    </Border>

    <!-- Finished + details -->
    <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,6">
          <TextBlock Text="Finished" FontWeight="SemiBold" DockPanel.Dock="Left"/>
          <TextBlock Text="Double-click a file to show it in its folder" Foreground="#9A9A94" FontSize="12"
                     HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
        </DockPanel>
        <ListBox x:Name="FinishedList" Grid.Row="1" BorderBrush="#E2E2DE" MinHeight="70"/>
        <Expander x:Name="DetailsExpander" Grid.Row="2" Header="Details" Margin="0,10,0,0">
          <TextBox x:Name="LogBox" Height="150" IsReadOnly="True" FontFamily="Consolas" FontSize="11.5"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                   Background="#FAFAF8" BorderBrush="#E2E2DE" Margin="0,6,0,0"/>
        </Expander>
      </Grid>
    </Border>

    <!-- Footer -->
    <DockPanel Grid.Row="5" LastChildFill="True">
      <Button x:Name="OpenFolderBtn" Style="{StaticResource Btn}" Content="Open downloads folder" DockPanel.Dock="Right"/>
      <Button x:Name="CheckBtn" Style="{StaticResource Btn}" Content="Check for updates" DockPanel.Dock="Right" Margin="0,0,8,0"/>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="FooterText" Foreground="#6B6B66" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="FolderText" Foreground="#9A9A94" FontSize="11.5" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'LogoImage','Banner','BannerText','UrlBox','UrlHint','EditReadyChk','KeepOrigChk','PasteBtn','ClearBtn',
               'DownloadBtn','CancelBtn','ItemText','TitleText','Bar','StatusText','FinishedList','DetailsExpander',
               'LogBox','FooterText','FolderText','OpenFolderBtn','CheckBtn') {
    $ui[$n] = $window.FindName($n)
}

function New-Bitmap([string]$Path) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.UriSource = New-Object System.Uri($Path)
    $bmp.EndInit()
    return $bmp
}
try { $ui.LogoImage.Source = New-Bitmap (Join-Path $AppDir 'logo.png') } catch { }
try { $window.Icon = New-Bitmap (Join-Path $AppDir 'logo.ico') } catch { }

$ui.EditReadyChk.IsChecked = $Settings.EditReady
$ui.KeepOrigChk.IsChecked = $Settings.KeepOriginal
$ui.KeepOrigChk.IsEnabled = $Settings.EditReady
$ui.FooterText.Text = "$AppName $Version"
$ui.FolderText.Text = "Saving to: $OutDir"

# ---------- Helpers (UI thread) ----------
function Add-Log([string]$Text) {
    if ($null -eq $Text) { return }
    $ui.LogBox.AppendText($Text + "`r`n")
    if ($ui.LogBox.Text.Length -gt 300000) { $ui.LogBox.Text = $ui.LogBox.Text.Substring(150000) }
    $ui.LogBox.ScrollToEnd()
}

function Show-Banner([string]$Text, [string]$Kind) {
    if ($Kind -eq 'error') {
        $ui.Banner.Background = '#FDECEC'; $ui.Banner.BorderBrush = '#F0A8A8'
    } else {
        $ui.Banner.Background = '#FFF4E5'; $ui.Banner.BorderBrush = '#F2C98B'
    }
    $ui.BannerText.Text = $Text
    $ui.Banner.Visibility = 'Visible'
}

function Save-Settings {
    try {
        [pscustomobject]@{ EditReady = [bool]$ui.EditReadyChk.IsChecked; KeepOriginal = [bool]$ui.KeepOrigChk.IsChecked } |
            ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

function Test-Tools {
    foreach ($t in 'yt-dlp.exe', 'ffmpeg.exe', 'ffprobe.exe', 'node.exe') {
        if (-not (Test-Path -LiteralPath (Join-Path $BinDir $t))) { return $false }
    }
    return $true
}

function Get-Links {
    $links = @()
    foreach ($l in ($ui.UrlBox.Text -split "`r?`n")) {
        $l = $l.Trim().Trim('"').Trim()
        if ($l -match '^https?://\S+$' -or ($env:MISFIT_DL_TEST_FILE_URLS -eq '1' -and $l -match '^file:///\S+$')) {
            if ($links -notcontains $l) { $links += $l }
        }
    }
    return ,$links
}

function Update-DownloadButton {
    $ui.DownloadBtn.IsEnabled = (-not $script:Busy) -and (-not $script:Checking) -and $script:ToolsReady -and
                                ((Get-Links).Count -gt 0)
    $ui.CheckBtn.IsEnabled = (-not $script:Busy) -and (-not $script:Checking)
}

$AutoCheckHours = 12   # while the app sits open and idle, check for updates this often
$script:LastUpdateCheck = Get-Date
$script:ManualCheck = $false

$script:Busy = $false
$script:Checking = $false
$script:ToolsReady = Test-Tools

# ---------- Shared state with the background worker ----------
$sync = [hashtable]::Synchronized(@{})
$sync.Log      = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.Finished = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Item = ''; $sync.Title = ''; $sync.Status = ''; $sync.Percent = -1.0
$sync.Cancel = $false; $sync.ProcId = 0; $sync.Ok = 0; $sync.Failed = 0

# ---------- Background worker (runs downloads and conversions off the UI thread) ----------
$WorkerScript = {
    param($sync, $Urls, $AppDir, $BinDir, $OutDir, $OrigDir, $MakeEditReady, $KeepOriginal, $AllowFileUrls)

    . (Join-Path $AppDir 'make-edit-ready.ps1')   # defines Get-EditReadyPlan
    $ytdlp  = Join-Path $BinDir 'yt-dlp.exe'
    $ffmpeg = Join-Path $BinDir 'ffmpeg.exe'

    function Log([string]$m) { $sync.Log.Enqueue($m) }

    function ConvertTo-ArgString([string]$a) {
        if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $bs = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq [char]'\') { $bs++ }
            elseif ($ch -eq [char]'"') { [void]$sb.Append([char]'\', 2 * $bs + 1); [void]$sb.Append('"'); $bs = 0 }
            else {
                if ($bs -gt 0) { [void]$sb.Append([char]'\', $bs); $bs = 0 }
                [void]$sb.Append($ch)
            }
        }
        if ($bs -gt 0) { [void]$sb.Append([char]'\', 2 * $bs) }
        [void]$sb.Append('"')
        return $sb.ToString()
    }

    # Runs a tool, calls $OnLine for each output line, returns the exit code
    function Invoke-Tool([string]$Exe, [string[]]$Argv, [scriptblock]$OnLine) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = (($Argv | ForEach-Object { ConvertTo-ArgString $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        $p = [System.Diagnostics.Process]::Start($psi)
        $sync.ProcId = $p.Id
        $errTask = $p.StandardError.ReadToEndAsync()
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) { [void](& $OnLine $line) }
        $p.WaitForExit()
        $sync.ProcId = 0
        foreach ($l in ($errTask.Result -split "`r?`n")) { if ($l.Trim()) { Log $l } }
        return $p.ExitCode
    }

    $total = $Urls.Count
    for ($i = 0; $i -lt $total; $i++) {
        if ($sync.Cancel) { break }
        $url = $Urls[$i]
        $script:linkLabel = "Link $($i + 1) of $total"
        $sync.Item = $script:linkLabel
        $sync.Title = $url
        $sync.Status = 'Starting download...'
        $sync.Percent = -1.0
        Log ''
        Log "=== $url"

        $list = Join-Path $env:TEMP ('misfit-dl-' + [guid]::NewGuid().ToString('N') + '.txt')
        if ($MakeEditReady) { $dlDir = $OrigDir } else { $dlDir = $OutDir }
        New-Item -ItemType Directory -Force -Path $dlDir | Out-Null

        $argv = @('-f', 'bv*+ba/b', '--merge-output-format', 'mp4',
                  '--ffmpeg-location', $BinDir, '--js-runtimes', ('node:' + (Join-Path $BinDir 'node.exe')),
                  '--no-continue', '-N', '4', '-P', $dlDir,
                  '--print-to-file', 'after_move:filepath', $list,
                  '--newline', '--color', 'never',
                  '--progress-template', 'download:[progress] %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(info.vcodec)s|%(info.title)s')
        if ($AllowFileUrls) { $argv += '--enable-file-urls' }
        $argv += $url

        $code = @(Invoke-Tool $ytdlp $argv {
            param($line)
            if ($line -match '^\[progress\]\s*(.*)$') {
                $parts = $Matches[1].Split([char]'|', 5)
                $pct = 0.0
                if ($parts[0] -match '([\d\.]+)') { [void][double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$pct) }
                if ($parts.Count -ge 4 -and $parts[3].Trim() -eq 'none') { $kind = 'audio' } else { $kind = 'video' }
                if ($parts.Count -ge 5 -and $parts[4].Trim()) { $sync.Title = $parts[4].Trim() }
                $sync.Percent = $pct
                $speed = ''; $eta = ''
                if ($parts.Count -ge 2) { $speed = $parts[1].Trim() }
                if ($parts.Count -ge 3) { $eta = $parts[2].Trim() }
                $sync.Status = ('Downloading {0}   {1:N1}%   {2}   ETA {3}' -f $kind, $pct, $speed, $eta)
            } elseif ($line -match '^\[download\] Downloading item (\d+) of (\d+)') {
                $sync.Item = "$($script:linkLabel)  -  playlist video $($Matches[1]) of $($Matches[2])"
                Log $line
            } elseif ($line -match '^\[Merger\]') {
                $sync.Status = 'Merging video and audio...'
                $sync.Percent = -1.0
                Log $line
            } else {
                Log $line
            }
        })[-1]

        if ($sync.Cancel) { Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue; break }

        $files = @()
        if (Test-Path -LiteralPath $list) {
            $files = @(Get-Content -LiteralPath $list -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -Unique)
            Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
        }
        if ($code -ne 0 -or $files.Count -eq 0) {
            Log "Download failed: $url"
            $sync.Finished.Enqueue([pscustomobject]@{ Ok = $false; Path = ''; Text = "Failed: $url" })
            $sync.Failed++
            if ($files.Count -eq 0) { continue }
        }

        foreach ($src in $files) {
            $src = $src.Trim()
            if ($sync.Cancel) { break }
            if (-not (Test-Path -LiteralPath $src)) { continue }
            $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
            $sync.Title = $name

            if (-not $MakeEditReady) {
                $sync.Finished.Enqueue([pscustomobject]@{ Ok = $true; Path = $src; Text = [System.IO.Path]::GetFileName($src) })
                $sync.Ok++
                continue
            }

            $dst = Join-Path $OutDir ($name + '.mp4')
            $sync.Status = 'Checking video...'
            $sync.Percent = -1.0
            $plan = Get-EditReadyPlan $src $dst $BinDir
            if (-not $plan) {
                Log "Skipped (no video stream): $src"
                continue
            }
            Log "Edit-ready: $($plan.Summary)"
            $script:duration = $plan.Duration
            $sync.Status = 'Making edit-ready copy...'
            if ($script:duration -gt 0) { $sync.Percent = 0.0 }

            $ffArgv = @('-hide_banner', '-loglevel', 'error', '-nostats', '-progress', 'pipe:1') + $plan.Args
            $fcode = @(Invoke-Tool $ffmpeg $ffArgv {
                param($line)
                if ($line -match '^out_time_us=(\d+)' -and $script:duration -gt 0) {
                    $pct = [math]::Min(100.0, ([double]$Matches[1] / 1000000.0) / $script:duration * 100.0)
                    # ffmpeg can report audio ahead of video; never let the bar move backwards
                    if ($pct -lt $sync.Percent) { $pct = $sync.Percent }
                    $sync.Percent = $pct
                    $sync.Status = ('Making edit-ready copy   {0:N1}%' -f $pct)
                }
            })[-1]

            if ($fcode -eq 0 -and -not $sync.Cancel) {
                $sync.Finished.Enqueue([pscustomobject]@{ Ok = $true; Path = $dst; Text = [System.IO.Path]::GetFileName($dst) })
                $sync.Ok++
                Log "Saved: $dst"
                if (-not $KeepOriginal -and $src -ne $dst) {
                    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
                }
            } else {
                if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
                if (-not $sync.Cancel) {
                    Log "Conversion failed: $src"
                    $sync.Finished.Enqueue([pscustomobject]@{ Ok = $false; Path = $src; Text = "Conversion failed: $name" })
                    $sync.Failed++
                }
            }
        }
    }
}

function Start-Downloads {
    $links = Get-Links
    if ($links.Count -eq 0) { return }
    Save-Settings
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $script:Busy = $true
    $sync.Cancel = $false; $sync.Ok = 0; $sync.Failed = 0
    $ui.UrlBox.IsReadOnly = $true
    $ui.EditReadyChk.IsEnabled = $false; $ui.KeepOrigChk.IsEnabled = $false
    $ui.PasteBtn.IsEnabled = $false; $ui.ClearBtn.IsEnabled = $false
    $ui.CancelBtn.IsEnabled = $true
    Update-DownloadButton

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerScript.ToString())
    [void]$ps.AddParameters(@{
        sync = $sync; Urls = [string[]]$links; AppDir = $AppDir; BinDir = $BinDir; OutDir = $OutDir; OrigDir = $OrigDir
        MakeEditReady = [bool]$ui.EditReadyChk.IsChecked; KeepOriginal = [bool]$ui.KeepOrigChk.IsChecked
        AllowFileUrls = ($env:MISFIT_DL_TEST_FILE_URLS -eq '1')
    })
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Complete-Downloads {
    try { $script:Job.PS.EndInvoke($script:Job.Handle) } catch { Add-Log ('Error: ' + $_.Exception.Message) }
    foreach ($e in $script:Job.PS.Streams.Error) { Add-Log ('Error: ' + $e.ToString()) }
    $script:Job.PS.Dispose(); $script:Job.RS.Dispose()
    $script:Job = $null
    $script:Busy = $false

    $ui.UrlBox.IsReadOnly = $false
    $ui.EditReadyChk.IsEnabled = $true; $ui.KeepOrigChk.IsEnabled = [bool]$ui.EditReadyChk.IsChecked
    $ui.PasteBtn.IsEnabled = $true; $ui.ClearBtn.IsEnabled = $true
    $ui.CancelBtn.IsEnabled = $false
    $ui.Bar.IsIndeterminate = $false

    if ($sync.Cancel) {
        $ui.ItemText.Text = 'Cancelled'
        $ui.TitleText.Text = 'Download cancelled.'
        $ui.StatusText.Text = ' '
        $ui.Bar.Value = 0
    } else {
        $ui.ItemText.Text = 'Done'
        $ui.Bar.Value = 100
        if ($sync.Failed -eq 0) {
            $ui.TitleText.Text = ('{0} file(s) saved.' -f $sync.Ok)
            $ui.StatusText.Text = "Saved to $OutDir"
            $ui.UrlBox.Clear()
        } else {
            $ui.TitleText.Text = ('{0} saved, {1} failed.' -f $sync.Ok, $sync.Failed)
            $ui.StatusText.Text = 'Open Details below to see what went wrong.'
            $ui.DetailsExpander.IsExpanded = $true
        }
    }
    Update-DownloadButton
}

function Stop-CurrentTool {
    $procId = $sync.ProcId
    if ($procId -gt 0) {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList '/T', '/F', '/PID', $procId -WindowStyle Hidden -Wait
    }
}

# ---------- Update check (pulls new versions from GitHub, installs missing tools) ----------
function Start-UpdateCheck([switch]$Manual) {
    $script:Checking = $true
    $script:ManualCheck = [bool]$Manual
    $script:LastUpdateCheck = Get-Date
    $ui.FooterText.Text = 'Checking for updates...'
    Update-DownloadButton
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PowerShellExe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $AppDir 'update.ps1') + '"'
    if ($Manual) { $psi.Arguments += ' -CheckAll' }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $script:UpdProc = [System.Diagnostics.Process]::Start($psi)
    $script:UpdErr = $script:UpdProc.StandardError.ReadToEndAsync()
    $script:UpdLine = $script:UpdProc.StandardOutput.ReadLineAsync()
}

function Step-UpdateCheck {
    # Show each line of updater output as it arrives
    while ($script:UpdLine -and $script:UpdLine.IsCompleted) {
        $l = $script:UpdLine.Result
        if ($null -eq $l) { $script:UpdLine = $null; break }
        if ($l.Trim()) { Add-Log $l; $ui.FooterText.Text = $l.Trim() }
        $script:UpdLine = $script:UpdProc.StandardOutput.ReadLineAsync()
    }
    if ($script:UpdLine -or -not $script:UpdProc.HasExited) { return }

    $code = $script:UpdProc.ExitCode
    $script:UpdProc = $null
    $script:Checking = $false
    $script:ToolsReady = Test-Tools

    if ($code -eq 10 -and (-not $Restarted -or $script:ManualCheck)) {
        # New version installed: reopen with it, carrying over any links already typed
        try { Set-Content -LiteralPath (Join-Path $StateDir 'pending-links.txt') -Value $ui.UrlBox.Text -Encoding UTF8 } catch { }
        Start-Process -FilePath $PowerShellExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"' + (Join-Path $AppDir 'VideoDownloader.ps1') + '"'), '-Restarted')
        $script:ClosingForRestart = $true
        $window.Close()
        return
    }
    if ($code -eq 10) {
        Show-Banner 'A new version was installed. Close and reopen Misfit Downloader to finish updating.' 'info'
    } elseif ($code -ne 0 -or -not $script:ToolsReady) {
        Show-Banner 'Could not download the tools Misfit Downloader needs. Check your internet connection, then close and reopen the app.' 'error'
    }
    if ($script:ToolsReady) {
        if ($code -eq 0) { $ui.Banner.Visibility = 'Collapsed' }
        if ($script:ManualCheck -and $code -eq 0) {
            $ui.FooterText.Text = "$AppName $Version - up to date (checked $((Get-Date).ToString('h:mm tt')))"
        } else {
            $ui.FooterText.Text = "$AppName $Version"
        }
    }
    $script:ManualCheck = $false
    Update-DownloadButton
}

# ---------- Events ----------
$ui.UrlBox.Add_TextChanged({
    if ($ui.UrlBox.Text.Length -eq 0) { $ui.UrlHint.Visibility = 'Visible' } else { $ui.UrlHint.Visibility = 'Collapsed' }
    Update-DownloadButton
})
$ui.PasteBtn.Add_Click({
    $clip = [System.Windows.Clipboard]::GetText()
    if ($clip) {
        $existing = $ui.UrlBox.Text.TrimEnd()
        if ($existing) { $ui.UrlBox.Text = $existing + "`r`n" + $clip.Trim() } else { $ui.UrlBox.Text = $clip.Trim() }
        $ui.UrlBox.CaretIndex = $ui.UrlBox.Text.Length
    }
})
$ui.ClearBtn.Add_Click({ $ui.UrlBox.Clear() })
$ui.EditReadyChk.Add_Click({ $ui.KeepOrigChk.IsEnabled = [bool]$ui.EditReadyChk.IsChecked; Save-Settings })
$ui.KeepOrigChk.Add_Click({ Save-Settings })
$ui.DownloadBtn.Add_Click({ Start-Downloads })
$ui.CancelBtn.Add_Click({
    $sync.Cancel = $true
    $ui.CancelBtn.IsEnabled = $false
    $ui.StatusText.Text = 'Cancelling...'
    Stop-CurrentTool
})
$ui.CheckBtn.Add_Click({ if (-not $script:Busy -and -not $script:Checking) { Start-UpdateCheck -Manual } })
$ui.OpenFolderBtn.Add_Click({
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    Start-Process explorer.exe -ArgumentList ('"' + $OutDir + '"')
})
$ui.FinishedList.Add_MouseDoubleClick({
    $item = $ui.FinishedList.SelectedItem
    if ($item -and $item.Tag -and (Test-Path -LiteralPath $item.Tag)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $item.Tag + '"')
    }
})

$window.Add_Closing({
    param($sender, $e)
    if ($script:Busy) {
        $answer = [System.Windows.MessageBox]::Show('A download is still running. Stop it and close?', $AppName, 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        $sync.Cancel = $true
        Stop-CurrentTool
    }
    if ($script:UpdProc -and -not $script:UpdProc.HasExited -and -not $script:ClosingForRestart) {
        try { $script:UpdProc.Kill() } catch { }
    }
})

# ---------- Timer: moves worker progress onto the screen ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $line = $null
    while ($sync.Log.TryDequeue([ref]$line)) { Add-Log $line }
    $f = $null
    while ($sync.Finished.TryDequeue([ref]$f)) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $li.Content = $f.Text
        $li.Tag = $f.Path
        $li.Padding = '6,4'
        if (-not $f.Ok) { $li.Foreground = '#B42318' }
        [void]$ui.FinishedList.Items.Add($li)
        $ui.FinishedList.ScrollIntoView($li)
    }
    if ($script:Busy) {
        $ui.ItemText.Text = $sync.Item
        $ui.TitleText.Text = $sync.Title
        $ui.StatusText.Text = $sync.Status
        if ($sync.Percent -lt 0) { $ui.Bar.IsIndeterminate = $true }
        else { $ui.Bar.IsIndeterminate = $false; $ui.Bar.Value = $sync.Percent }
        if ($script:Job -and $script:Job.Handle.IsCompleted) { Complete-Downloads }
    }
    if ($script:UpdProc) { Step-UpdateCheck }
    # Left open for a long time? Check again, but only while idle with no links typed in
    elseif (-not $script:Busy -and -not $script:Checking -and $ui.UrlBox.Text.Trim().Length -eq 0 -and
            ((Get-Date) - $script:LastUpdateCheck).TotalHours -ge $AutoCheckHours) {
        Start-UpdateCheck
    }
})

# ---------- Start ----------
$pendingFile = Join-Path $StateDir 'pending-links.txt'
if (Test-Path -LiteralPath $pendingFile) {
    try { $ui.UrlBox.Text = (Get-Content -LiteralPath $pendingFile -Raw).Trim() } catch { }
    Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue
}

if ($Screenshot) {
    # Render a sample state for documentation, without showing the window
    $ui.UrlBox.Text = "https://www.youtube.com/watch?v=example"
    $ui.ItemText.Text = 'Link 1 of 1'
    $ui.TitleText.Text = 'Example video title'
    $ui.StatusText.Text = 'Making edit-ready copy   42.0%'
    $ui.Bar.Value = 42
    $ui.FolderText.Text = 'Saving to: C:\Users\you\Downloads\Misfit Downloader'
    foreach ($t in 'Product launch teaser.mp4', 'Behind the scenes [4K].mp4') {
        $li = New-Object System.Windows.Controls.ListBoxItem; $li.Content = $t; $li.Padding = '6,4'; [void]$ui.FinishedList.Items.Add($li)
    }
    $root = $window.Content
    $window.Content = $null
    $host2 = New-Object System.Windows.Controls.Border
    $host2.Resources = $window.Resources
    $host2.Background = $window.Background
    $host2.Child = $root
    $w = 760; $h = 760
    $host2.Measure((New-Object System.Windows.Size($w, $h)))
    $host2.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
    $host2.UpdateLayout()
    $pw = [int]($w * 2); $ph = [int]($h * 2)
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($pw, $ph, 192.0, 192.0, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($host2)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [System.IO.File]::Create($Screenshot); $enc.Save($fs); $fs.Close()
    exit 0
}

$window.Add_Loaded({
    $ui.UrlBox.Focus() | Out-Null
    if (-not $NoUpdate) { Start-UpdateCheck }
    elseif (-not $script:ToolsReady) {
        Show-Banner 'Some tools are missing. Close and reopen Misfit Downloader to download them.' 'error'
    }
    Update-DownloadButton
})
$timer.Start()
[void]$window.ShowDialog()
$timer.Stop()
