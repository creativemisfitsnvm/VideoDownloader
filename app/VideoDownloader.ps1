# Misfit Downloader - desktop app
# Paste links -> downloads the best quality available -> makes an edit-ready MP4
# (H.264 + AAC, same resolution and frame rate) for Resolve / After Effects.
param(
    [switch]$NoUpdate,          # skip the update check
    [switch]$Restarted,         # set after a self-update, prevents restart loops
    [string]$Screenshot = '',   # maintainers: render the window to this PNG and exit
    [string]$Theme = ''         # Dark or Light: overrides the saved theme (used for screenshots)
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
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
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
$Settings = [pscustomobject]@{ EditReady = $true; KeepOriginal = $true; Theme = 'Dark'; OutputFolder = '' }
try {
    if (Test-Path -LiteralPath $SettingsFile) {
        $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        if ($null -ne $saved.EditReady) { $Settings.EditReady = [bool]$saved.EditReady }
        if ($null -ne $saved.KeepOriginal) { $Settings.KeepOriginal = [bool]$saved.KeepOriginal }
        if ($saved.Theme -in 'Dark', 'Light') { $Settings.Theme = [string]$saved.Theme }
        if ($saved.OutputFolder) { $Settings.OutputFolder = [string]$saved.OutputFolder }
    }
} catch { }

# A folder chosen with "Change..." replaces the default (if it can still be created/written)
$DefaultOutDir = $OutDir
$script:CustomOutDir = ''
if ($Settings.OutputFolder -and -not $Screenshot) {
    try {
        New-Item -ItemType Directory -Force -Path $Settings.OutputFolder -ErrorAction Stop | Out-Null
        $OutDir = $Settings.OutputFolder
        $OrigDir = Join-Path $OutDir 'Originals'
        $script:CustomOutDir = $OutDir
    } catch { }
}

# ---------- Window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Misfit Downloader" Width="760" Height="900" MinWidth="620" MinHeight="740"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource Bg}"
        FontFamily="Segoe UI" FontSize="13" Foreground="{DynamicResource Fg}" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
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
      <Setter Property="Background" Value="{DynamicResource AccentBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource AccentFg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentBg}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="26,9"/>
    </Style>
    <Style x:Key="LinkBtn" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Padding" Value="0,4"/>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource Card}"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardBorder}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="18"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource InputBg}"/>
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BtnBorder}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource Fg}"/>
      <Setter Property="SelectionBrush" Value="{DynamicResource Muted}"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="Margin" Value="0,0,24,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="box" Width="18" Height="18" CornerRadius="4" BorderThickness="1.5" VerticalAlignment="Center"
                      BorderBrush="{DynamicResource CheckBorder}" Background="{DynamicResource InputBg}">
                <Path x:Name="mark" Data="M 3,7.5 L 6.3,10.8 L 12,4.5" Stroke="{DynamicResource AccentFg}" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box" Property="Background" Value="{DynamicResource AccentBg}"/>
                <Setter TargetName="box" Property="BorderBrush" Value="{DynamicResource AccentBg}"/>
                <Setter TargetName="mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bg" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bg" Property="Background" Value="{DynamicResource Select}"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border CornerRadius="4" Background="{DynamicResource ScrollThumb}" Margin="2"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="12"/>
      <Setter Property="MinWidth" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="MinHeight" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" IsDirectionReversed="False">
                  <Track.Thumb><Thumb Style="{StaticResource ScrollThumb}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
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
                   Foreground="{DynamicResource Muted}" TextWrapping="Wrap" Margin="0,4,0,0"/>
      </StackPanel>
    </Grid>

    <!-- Update banner -->
    <Border x:Name="Banner" Grid.Row="1" Visibility="Collapsed" BorderThickness="1" CornerRadius="8" Padding="12,9" Margin="0,0,0,14">
      <TextBlock x:Name="BannerText" TextWrapping="Wrap"/>
    </Border>

    <!-- Links -->
    <Border Grid.Row="2" Style="{StaticResource Card}">
      <StackPanel>
        <TextBlock Text="Video links" FontWeight="SemiBold" Margin="0,0,0,6"/>
        <Grid>
          <TextBox x:Name="UrlBox" Height="84" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto"
                   HorizontalScrollBarVisibility="Auto" Padding="8,6" FontSize="13"/>
          <TextBlock x:Name="UrlHint" IsHitTestVisible="False" Foreground="{DynamicResource Faint}" Margin="12,8,0,0" TextWrapping="Wrap"
                     Text="Paste one or more links (one per line). You can keep adding links while others download and convert."/>
        </Grid>
        <WrapPanel Margin="0,12,0,0">
          <CheckBox x:Name="EditReadyChk" Content="Make edit-ready MP4 (H.264 + AAC)"/>
          <CheckBox x:Name="KeepOrigChk" Content="Keep original download"/>
        </WrapPanel>
        <DockPanel Margin="0,10,0,0" LastChildFill="True">
          <TextBlock Text="Save to:" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" Margin="0,0,6,0" DockPanel.Dock="Left"/>
          <Button x:Name="DefaultFolderBtn" Style="{StaticResource LinkBtn}" Content="Use default" DockPanel.Dock="Right" Margin="12,0,0,0" Visibility="Collapsed"/>
          <Button x:Name="ChangeFolderBtn" Style="{StaticResource LinkBtn}" Content="Change..." DockPanel.Dock="Right" Margin="12,0,0,0"
                  Foreground="{DynamicResource Fg}" FontWeight="SemiBold"/>
          <TextBlock x:Name="FolderText" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
        </DockPanel>
        <DockPanel Margin="0,14,0,0" LastChildFill="False">
          <Button x:Name="PasteBtn" Style="{StaticResource Btn}" Content="Paste" Margin="0,0,8,0" DockPanel.Dock="Left"/>
          <Button x:Name="ClearBtn" Style="{StaticResource Btn}" Content="Clear" DockPanel.Dock="Left"/>
          <Button x:Name="DownloadBtn" Style="{StaticResource PrimaryBtn}" Content="Add to queue" DockPanel.Dock="Right"/>
        </DockPanel>
      </StackPanel>
    </Border>

    <!-- Now working on: two lanes that run at the same time -->
    <Border x:Name="ProgressCard" Grid.Row="3" Style="{StaticResource Card}">
      <StackPanel>
        <DockPanel>
          <TextBlock Text="Downloading" Foreground="{DynamicResource Muted}" FontSize="12" DockPanel.Dock="Left"/>
          <TextBlock x:Name="QueueSummary" Foreground="{DynamicResource Faint}" FontSize="12" HorizontalAlignment="Right"/>
        </DockPanel>
        <TextBlock x:Name="DlTitle" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis" Margin="0,2,0,0" Text="Nothing downloading"/>
        <ProgressBar x:Name="DlBar" Height="6" Margin="0,8,0,6" Minimum="0" Maximum="100" Value="0"
                     Foreground="{DynamicResource AccentBg}" Background="{DynamicResource Track}" BorderThickness="0"/>
        <TextBlock x:Name="DlStatus" Foreground="{DynamicResource Body}" TextTrimming="CharacterEllipsis" Text="Add links above to start."/>
        <Border Height="1" Background="{DynamicResource CardBorder}" Margin="0,14,0,12"/>
        <TextBlock Text="Making edit-ready copy" Foreground="{DynamicResource Muted}" FontSize="12"/>
        <TextBlock x:Name="CvTitle" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis" Margin="0,2,0,0" Text="Nothing converting"/>
        <ProgressBar x:Name="CvBar" Height="6" Margin="0,8,0,6" Minimum="0" Maximum="100" Value="0"
                     Foreground="{DynamicResource AccentBg}" Background="{DynamicResource Track}" BorderThickness="0"/>
        <TextBlock x:Name="CvStatus" Foreground="{DynamicResource Body}" TextTrimming="CharacterEllipsis" Text=" "/>
      </StackPanel>
    </Border>

    <!-- Queue + details -->
    <Border Grid.Row="4" Style="{StaticResource Card}" Margin="0,0,0,12">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Margin="0,0,0,6">
          <TextBlock Text="Queue" FontWeight="SemiBold" DockPanel.Dock="Left"/>
          <TextBlock Text="Double-click a finished file to show it in its folder" Foreground="{DynamicResource Faint}" FontSize="12"
                     HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
        </DockPanel>
        <ListBox x:Name="QueueList" Grid.Row="1" MinHeight="90" Padding="3" HorizontalContentAlignment="Stretch"
                 ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                 Background="{DynamicResource InputBg}" Foreground="{DynamicResource Fg}" BorderBrush="{DynamicResource CardBorder}"/>
        <DockPanel Grid.Row="2" Margin="0,8,0,0" LastChildFill="False">
          <Button x:Name="DetailsBtn" Style="{StaticResource LinkBtn}" Content="Show details" DockPanel.Dock="Left"/>
          <Button x:Name="ClearDoneBtn" Style="{StaticResource Btn}" Content="Clear finished" DockPanel.Dock="Right" Padding="12,5" IsEnabled="False"/>
          <Button x:Name="CancelAllBtn" Style="{StaticResource Btn}" Content="Cancel all" DockPanel.Dock="Right" Padding="12,5" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="CancelBtn" Style="{StaticResource Btn}" Content="Cancel selected" DockPanel.Dock="Right" Padding="12,5" Margin="0,0,8,0" IsEnabled="False"/>
        </DockPanel>
        <TextBox x:Name="LogBox" Grid.Row="3" Height="130" Visibility="Collapsed" IsReadOnly="True" FontFamily="Consolas" FontSize="11.5"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"
                 Background="{DynamicResource LogBg}" BorderBrush="{DynamicResource CardBorder}" Margin="0,4,0,0"/>
      </Grid>
    </Border>

    <!-- Footer -->
    <DockPanel Grid.Row="5" LastChildFill="True">
      <Button x:Name="OpenFolderBtn" Style="{StaticResource Btn}" Content="Open downloads folder" DockPanel.Dock="Right"/>
      <Button x:Name="CheckBtn" Style="{StaticResource Btn}" Content="Check for updates" DockPanel.Dock="Right" Margin="0,0,8,0"/>
      <Button x:Name="ThemeBtn" Style="{StaticResource Btn}" DockPanel.Dock="Right" Margin="0,0,8,0" Padding="11,8">
        <TextBlock x:Name="ThemeIcon" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center"/>
      </Button>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="FooterText" Foreground="{DynamicResource Muted}" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </DockPanel>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'LogoImage','Banner','BannerText','UrlBox','UrlHint','EditReadyChk','KeepOrigChk','PasteBtn','ClearBtn',
               'DownloadBtn','QueueSummary','DlTitle','DlBar','DlStatus','CvTitle','CvBar','CvStatus',
               'QueueList','DetailsBtn','CancelBtn','CancelAllBtn','ClearDoneBtn',
               'LogBox','FooterText','FolderText','ChangeFolderBtn','DefaultFolderBtn','OpenFolderBtn','CheckBtn','ThemeBtn','ThemeIcon') {
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
try { $window.Icon = New-Bitmap (Join-Path $AppDir 'logo.ico') } catch { }

# ---------- Themes ----------
$Palettes = @{
    Light = @{
        Bg = '#F3F3F1'; Card = '#FFFFFF'; CardBorder = '#E2E2DE'; Fg = '#161616'; Muted = '#6B6B66'; Faint = '#9A9A94'; Body = '#4A4A46'
        BtnBg = '#FFFFFF'; BtnBorder = '#CFCFCB'; AccentBg = '#111111'; AccentFg = '#FFFFFF'; InputBg = '#FFFFFF'; LogBg = '#FAFAF8'
        Track = '#E9E9E5'; CheckBorder = '#A8A8A2'; ScrollThumb = '#C9C9C4'; Hover = '#F1F1EE'; Select = '#E6E6E2'; Error = '#B42318'
        InfoBg = '#FFF4E5'; InfoBorder = '#F2C98B'; ErrBg = '#FDECEC'; ErrBorder = '#F0A8A8'
    }
    Dark = @{
        Bg = '#121212'; Card = '#1C1C1C'; CardBorder = '#2C2C2C'; Fg = '#F0F0EC'; Muted = '#A3A39D'; Faint = '#77776F'; Body = '#C8C8C2'
        BtnBg = '#242424'; BtnBorder = '#3A3A3A'; AccentBg = '#F0F0EC'; AccentFg = '#111111'; InputBg = '#161616'; LogBg = '#141414'
        Track = '#2E2E2E'; CheckBorder = '#5A5A55'; ScrollThumb = '#45453F'; Hover = '#262626'; Select = '#303030'; Error = '#FF8A7A'
        InfoBg = '#33291A'; InfoBorder = '#6B5426'; ErrBg = '#3A1E1E'; ErrBorder = '#7A3434'
    }
}

# Dark title bar on Windows 10 (20H1+) and 11
function Set-TitleBarTheme {
    try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
        if ($hwnd -ne [IntPtr]::Zero) {
            $dark = [int]($script:ThemeName -eq 'Dark')
            [void][MisfitDl.Native]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4)
        }
    } catch { }
}

function Set-Theme([string]$Name) {
    if ($Name -ne 'Light') { $Name = 'Dark' }
    $script:ThemeName = $Name
    $palette = $Palettes[$Name]
    foreach ($key in $palette.Keys) {
        # ::new (not New-Object): WPF can't use PowerShell-wrapped brush objects
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key]))
        $brush.Freeze()
        $window.Resources[$key] = $brush.PSObject.BaseObject
    }
    # Corner square between two scrollbars
    $window.Resources[[System.Windows.SystemColors]::ControlBrushKey] = $window.Resources['Card']
    if ($Name -eq 'Dark') { $logo = 'logo-dark.png' } else { $logo = 'logo.png' }
    try { $ui.LogoImage.Source = New-Bitmap (Join-Path $AppDir $logo) } catch { }
    if ($Name -eq 'Dark') {
        $ui.ThemeIcon.Text = [string][char]0xE706   # sun
        $ui.ThemeBtn.ToolTip = 'Switch to light mode'
    } else {
        $ui.ThemeIcon.Text = [string][char]0xE708   # moon
        $ui.ThemeBtn.ToolTip = 'Switch to dark mode'
    }
    Set-TitleBarTheme
}

$startTheme = $Settings.Theme
if ($Theme -in 'Dark', 'Light') { $startTheme = $Theme }
Set-Theme $startTheme
$ui.EditReadyChk.IsChecked = $Settings.EditReady
$ui.KeepOrigChk.IsChecked = $Settings.KeepOriginal
$ui.KeepOrigChk.IsEnabled = $Settings.EditReady
$ui.FooterText.Text = "$AppName $Version"

# ---------- Helpers (UI thread) ----------
function Add-Log([string]$Text) {
    if ($null -eq $Text) { return }
    $ui.LogBox.AppendText($Text + "`r`n")
    if ($ui.LogBox.Text.Length -gt 300000) { $ui.LogBox.Text = $ui.LogBox.Text.Substring(150000) }
    $ui.LogBox.ScrollToEnd()
}

function Show-Banner([string]$Text, [string]$Kind) {
    if ($Kind -eq 'error') { $bg = 'ErrBg'; $border = 'ErrBorder' } else { $bg = 'InfoBg'; $border = 'InfoBorder' }
    # Resource references follow theme changes automatically
    $ui.Banner.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $bg)
    $ui.Banner.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $border)
    $ui.BannerText.Text = $Text
    $ui.Banner.Visibility = 'Visible'
}

function Show-OutputFolder {
    $ui.FolderText.Text = $script:OutDir
    $ui.FolderText.ToolTip = $script:OutDir
    if ($script:CustomOutDir) { $ui.DefaultFolderBtn.Visibility = 'Visible' } else { $ui.DefaultFolderBtn.Visibility = 'Collapsed' }
}

# Modern Windows folder picker (IFileOpenDialog); falls back to the classic one if it isn't available
$FolderPickerSource = @"
using System;
using System.Runtime.InteropServices;
namespace MisfitDl {
  [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialogCom { }
  [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IShellItem {
    void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
    void GetParent(out IShellItem ppsi);
    void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
    void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
    void Compare(IShellItem psi, uint hint, out int piOrder);
  }
  [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFileOpenDialog {
    [PreserveSig] int Show(IntPtr parent);
    void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
    void SetFileTypeIndex(uint iFileType);
    void GetFileTypeIndex(out uint piFileType);
    void Advise(IntPtr pfde, out uint pdwCookie);
    void Unadvise(uint dwCookie);
    void SetOptions(uint fos);
    void GetOptions(out uint pfos);
    void SetDefaultFolder(IShellItem psi);
    void SetFolder(IShellItem psi);
    void GetFolder(out IShellItem ppsi);
    void GetCurrentSelection(out IShellItem ppsi);
    void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
    void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
    void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
    void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
    void GetResult(out IShellItem ppsi);
  }
  public static class FolderPicker {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IShellItem item);
    // Returns the chosen folder, or null if the user cancelled
    public static string Pick(IntPtr owner, string title, string start) {
      IFileOpenDialog dlg = (IFileOpenDialog)new FileOpenDialogCom();
      try {
        dlg.SetOptions(0x20 | 0x40 | 0x800);   // pick folders, file system only, path must exist
        dlg.SetTitle(title);
        dlg.SetOkButtonLabel("Use this folder");
        if (!string.IsNullOrEmpty(start) && System.IO.Directory.Exists(start)) {
          Guid iid = typeof(IShellItem).GUID;
          IShellItem folder;
          SHCreateItemFromParsingName(start, IntPtr.Zero, ref iid, out folder);
          dlg.SetFolder(folder);
        }
        if (dlg.Show(owner) != 0) return null;
        IShellItem result;
        dlg.GetResult(out result);
        string path;
        result.GetDisplayName(0x80058000, out path);   // SIGDN_FILESYSPATH
        return path;
      } finally { Marshal.ReleaseComObject(dlg); }
    }
  }
}
"@

function Select-OutputFolder {
    $owner = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    try {
        if (-not ('MisfitDl.FolderPicker' -as [type])) { Add-Type -TypeDefinition $FolderPickerSource }
        return [MisfitDl.FolderPicker]::Pick($owner, 'Choose where Misfit Downloader saves videos', $script:OutDir)
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Choose where Misfit Downloader saves videos'
        $fb.SelectedPath = $script:OutDir
        if ($fb.ShowDialog() -eq 'OK') { return $fb.SelectedPath }
        return $null
    }
}

# Switches the save location for links added from now on (links already queued keep theirs)
function Set-OutputFolder([string]$Folder, [bool]$IsDefault) {
    try {
        New-Item -ItemType Directory -Force -Path $Folder -ErrorAction Stop | Out-Null
        $probe = Join-Path $Folder ('.misfit-write-test-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        [void][System.Windows.MessageBox]::Show("Misfit Downloader can't save files in that folder:`n$Folder`n`nPlease choose a different one.", $AppName, 'OK', 'Warning')
        return
    }
    $script:OutDir = $Folder
    $script:OrigDir = Join-Path $Folder 'Originals'
    if ($IsDefault) { $script:CustomOutDir = '' } else { $script:CustomOutDir = $Folder }
    Show-OutputFolder
    Save-Settings
    if (Test-QueueBusy) { Add-Log "Save location changed to $Folder (links already in the queue keep their original location)." }
}

function Save-Settings {
    try {
        [pscustomobject]@{ EditReady = [bool]$ui.EditReadyChk.IsChecked; KeepOriginal = [bool]$ui.KeepOrigChk.IsChecked; Theme = $script:ThemeName; OutputFolder = $script:CustomOutDir } |
            ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

# Showing the log makes the window taller (as far as the screen allows) so the Finished list keeps its room
$script:DetailsGrowth = 0
function Set-DetailsVisible([bool]$Show) {
    if ($Show) {
        if ($ui.LogBox.Visibility -eq 'Visible') { return }
        $ui.LogBox.Visibility = 'Visible'; $ui.DetailsBtn.Content = 'Hide details'; $ui.LogBox.ScrollToEnd()
        if ($window.IsLoaded -and $window.WindowState -eq 'Normal') {
            $area = [System.Windows.SystemParameters]::WorkArea
            $grow = [Math]::Min(150, $area.Height - $window.ActualHeight)
            if ($grow -gt 0) {
                $window.Height = $window.ActualHeight + $grow
                if ($window.Top + $window.Height -gt $area.Bottom) { $window.Top = [Math]::Max($area.Top, $area.Bottom - $window.Height) }
                $script:DetailsGrowth = $grow
            }
        }
    } else {
        if ($ui.LogBox.Visibility -ne 'Visible') { return }
        $ui.LogBox.Visibility = 'Collapsed'; $ui.DetailsBtn.Content = 'Show details'
        if ($script:DetailsGrowth -gt 0 -and $window.WindowState -eq 'Normal') {
            $window.Height = [Math]::Max($window.MinHeight, $window.ActualHeight - $script:DetailsGrowth)
        }
        $script:DetailsGrowth = 0
    }
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

$AutoCheckHours = 12   # while the app sits open and idle, check for updates this often
$script:LastUpdateCheck = Get-Date
$script:ManualCheck = $false
$script:Checking = $false
$script:ToolsReady = Test-Tools

# ---------- Queue ----------
# Links go into a download queue. A download lane and a conversion lane run at the same time in the
# background, so the next video downloads while the previous one is being made edit-ready.
# Item states: Waiting -> Downloading -> Waiting to convert -> Converting -> Done | Failed | Cancelled
$ActiveStates = @('Waiting', 'Downloading', 'Waiting to convert', 'Converting')

$sync = [hashtable]::Synchronized(@{})
$sync.Log      = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.DlQueue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.CvQueue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Items    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.DlLane   = [hashtable]::Synchronized(@{ Active = $false; Title = ''; Status = ''; Percent = -1.0 })
$sync.CvLane   = [hashtable]::Synchronized(@{ Active = $false; Title = ''; Status = ''; Percent = -1.0 })
$sync.DlItem = ''; $sync.CvItem = ''; $sync.DlProc = 0; $sync.CvProc = 0
$sync.Shutdown = $false

# Shared by the window and both background lanes
$WorkerLib = @'
function Log([string]$m) { $sync.Log.Enqueue($m) }

function New-QueueItem([string]$Url, [bool]$EditReady, [bool]$KeepOriginal) {
    $i = [hashtable]::Synchronized(@{})
    $i.Id = [guid]::NewGuid().ToString('N'); $i.Url = $Url; $i.Title = $Url
    $i.State = 'Waiting'; $i.Detail = ''; $i.Path = ''
    $i.EditReady = $EditReady; $i.KeepOriginal = $KeepOriginal; $i.Cancel = $false
    $i.OutDir = ''; $i.OrigDir = ''
    return $i
}

function Stop-Tree([int]$ProcessId) {
    if ($ProcessId -gt 0) { $null = & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /T /F /PID $ProcessId 2>&1 }
}

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

# Runs a tool for a queue item, calls $OnLine for each output line, returns the exit code.
# $ToolLane is 'Dl' or 'Cv' so the window can stop the right process when an item is cancelled.
function Invoke-Tool([string]$Exe, [string[]]$Argv, [scriptblock]$OnLine, [string]$ToolLane, $ToolItem) {
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
    $sync[$ToolLane + 'Proc'] = $p.Id
    if ($ToolItem.Cancel -or $sync.Shutdown) { Stop-Tree $p.Id }   # cancelled while starting
    $errTask = $p.StandardError.ReadToEndAsync()
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) { [void](& $OnLine $line) }
    $p.WaitForExit()
    $sync[$ToolLane + 'Proc'] = 0
    foreach ($l in ($errTask.Result -split "`r?`n")) { if ($l.Trim()) { Log $l } }
    return $p.ExitCode
}

# vimeo.com links -> Vimeo's embed player link (keeps the privacy hash of unlisted videos)
function Get-VimeoPlayerUrl([string]$Link) {
    $id = $null; $hash = $null
    if ($Link -match '^https?://(?:www\.)?vimeo\.com/(\d+)(?:/([0-9a-f]{6,}))?/?(?:[?#].*)?$') {
        $id = $Matches[1]; $hash = $Matches[2]
        if (-not $hash -and $Link -match '[?&]h=([0-9a-f]+)') { $hash = $Matches[1] }
    } elseif ($Link -match '^https?://(?:www\.)?vimeo\.com/(?:channels/[^/]+|groups/[^/]+/videos|showcase/\d+/video|album/\d+/video)/(\d+)/?(?:[?#].*)?$') {
        $id = $Matches[1]
    }
    if (-not $id) { return $null }
    $player = "https://player.vimeo.com/video/$id"
    if ($hash) { $player += "?h=$hash" }
    return $player
}
'@

# ---------- Download lane ----------
$DownloadLoop = @'
$ytdlp = Join-Path $BinDir 'yt-dlp.exe'
$lane = $sync.DlLane

# Hands each finished file to the conversion lane as soon as yt-dlp has saved it (playlists too)
$handOff = {
    if (-not (Test-Path -LiteralPath $list)) { return }
    foreach ($f in @(Get-Content -LiteralPath $list -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $f = $f.Trim()
        if (-not $f -or $script:seen.ContainsKey($f) -or -not (Test-Path -LiteralPath $f)) { continue }
        $script:seen[$f] = $true
        if ($script:fileCount -eq 0) { $target = $item }
        else {
            $target = New-QueueItem $item.Url $item.EditReady $item.KeepOriginal
            $target.OutDir = $item.OutDir; $target.OrigDir = $item.OrigDir
            [void]$sync.Items.Add($target)
        }
        $script:fileCount++
        $target.Title = [System.IO.Path]::GetFileNameWithoutExtension($f)
        if ($item.EditReady) {
            $target.State = 'Waiting to convert'; $target.Detail = ''
            $sync.CvQueue.Enqueue(@{ Item = $target; Src = $f })
        } else {
            $target.State = 'Done'; $target.Detail = 'Downloaded'; $target.Path = $f
        }
    }
}

$onYtLine = {
    param($line)
    if ($line -match '^\[progress\]\s*(.*)$') {
        $parts = $Matches[1].Split([char]'|', 7)
        $pct = 0.0
        if ($parts[0] -match '([\d\.]+)') { [void][double]::TryParse($Matches[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$pct) }
        $kind = 'video'
        if ($parts.Count -ge 4 -and $parts[3].Trim() -eq 'none') { $kind = 'audio' }
        $where = ''
        if ($parts.Count -ge 6 -and $parts[4].Trim() -match '^\d+$' -and $parts[5].Trim() -match '^\d+$') {
            $where = " (video $($parts[4].Trim()) of $($parts[5].Trim()))"
        }
        if ($parts.Count -ge 7 -and $parts[6].Trim()) {
            $lane.Title = $parts[6].Trim()
            if ($script:fileCount -eq 0) { $item.Title = $parts[6].Trim() }
        }
        $speed = ''; $eta = ''
        if ($parts.Count -ge 2) { $speed = $parts[1].Trim() }
        if ($parts.Count -ge 3) { $eta = $parts[2].Trim() }
        $lane.Percent = $pct
        $lane.Status = ('Downloading {0}{1}   {2:N1}%   {3}   ETA {4}' -f $kind, $where, $pct, $speed, $eta)
        if ($script:fileCount -eq 0) { $item.Detail = ('Downloading {0:N0}%' -f $pct) }
    } elseif ($line -match '^\[Merger\]') {
        $lane.Status = 'Merging video and audio...'
        $lane.Percent = -1.0
        if ($script:fileCount -eq 0) { $item.Detail = 'Merging...' }
        Log $line
        & $handOff
    } else {
        Log $line
        & $handOff
    }
}

while (-not $sync.Shutdown) {
    $item = $null
    if (-not $sync.DlQueue.TryDequeue([ref]$item)) { Start-Sleep -Milliseconds 250; continue }
    if ($item.Cancel) { $item.State = 'Cancelled'; $item.Detail = ''; continue }
    $list = Join-Path $env:TEMP ('misfit-dl-' + [guid]::NewGuid().ToString('N') + '.txt')
    try {
        $sync.DlItem = $item.Id
        $item.State = 'Downloading'; $item.Detail = 'Starting...'
        $lane.Title = $item.Url; $lane.Status = 'Starting download...'; $lane.Percent = -1.0; $lane.Active = $true
        Log ''
        Log "=== $($item.Url)"
        $script:seen = @{}
        $script:fileCount = 0

        $itemOut = $item.OutDir; if (-not $itemOut) { $itemOut = $OutDir }
        $itemOrig = $item.OrigDir; if (-not $itemOrig) { $itemOrig = $OrigDir }
        if ($item.EditReady) { $dlDir = $itemOrig } else { $dlDir = $itemOut }
        New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
        $argv = @('-f', 'bv*+ba/b', '--merge-output-format', 'mp4',
                  '--ffmpeg-location', $BinDir, '--js-runtimes', ('node:' + (Join-Path $BinDir 'node.exe')),
                  '--no-continue', '-N', '4', '-P', $dlDir,
                  '--print-to-file', 'after_move:filepath', $list,
                  '--newline', '--color', 'never',
                  '--progress-template', 'download:[progress] %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(info.vcodec)s|%(info.playlist_index)s|%(info.n_entries)s|%(info.title)s')
        if ($AllowFileUrls) { $argv += '--enable-file-urls' }

        # Vimeo's website now needs a login in yt-dlp, but its embed player doesn't:
        # try the player link first, then the original link (in case a later yt-dlp fixes the site)
        $attempts = @()
        $playerUrl = Get-VimeoPlayerUrl $item.Url
        if ($playerUrl) { $attempts += $playerUrl }
        $attempts += $item.Url
        $code = 1
        foreach ($attempt in $attempts) {
            if ($item.Cancel) { break }
            if ($attempt -ne $item.Url) { Log "Vimeo link: using the embed player ($attempt)" }
            elseif ($attempts.Count -gt 1) { Log 'Trying the original Vimeo link instead...'; $lane.Status = 'Trying another way...' }
            $code = @(Invoke-Tool $ytdlp ($argv + @($attempt)) $onYtLine 'Dl' $item)[-1]
            & $handOff
            if ($script:fileCount -gt 0) { break }   # something was saved: don't download it twice
        }

        if ($item.Cancel -and $script:fileCount -eq 0) {
            $item.State = 'Cancelled'; $item.Detail = ''
        } elseif ($script:fileCount -eq 0) {
            $item.State = 'Failed'; $item.Detail = 'Download failed (see details)'
            Log "Download failed: $($item.Url)"
            if ($playerUrl) { Log 'Vimeo hint: private, login-only or embed-restricted Vimeo videos cannot be downloaded.' }
        } elseif ($code -ne 0 -and -not $item.Cancel) {
            Log "Some videos from this link could not be downloaded: $($item.Url)"
        }
    } catch {
        Log "Error: $($_.Exception.Message)"
        if ($item.State -eq 'Downloading') { $item.State = 'Failed'; $item.Detail = 'Download failed (see details)' }
    } finally {
        Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
        $sync.DlItem = ''; $sync.DlProc = 0
        $lane.Active = $false
    }
}
'@

# ---------- Conversion lane ----------
$ConvertLoop = @'
. (Join-Path $AppDir 'make-edit-ready.ps1')   # defines Get-EditReadyPlan
$ffmpeg = Join-Path $BinDir 'ffmpeg.exe'
$lane = $sync.CvLane

$onProgress = {
    param($line)
    if ($line -match '^out_time_us=(\d+)' -and $script:duration -gt 0) {
        $pct = [math]::Min(100.0, ([double]$Matches[1] / 1000000.0) / $script:duration * 100.0)
        # ffmpeg can report audio ahead of video; never let the bar move backwards
        if ($pct -lt $lane.Percent) { $pct = $lane.Percent }
        $lane.Percent = $pct
        $lane.Status = ('Making edit-ready copy{0}   {1:N1}%' -f $script:engine, $pct)
        $item.Detail = ('Converting {0:N0}%' -f $pct)
    }
}

while (-not $sync.Shutdown) {
    $job = $null
    if (-not $sync.CvQueue.TryDequeue([ref]$job)) { Start-Sleep -Milliseconds 250; continue }
    $item = $job.Item
    $src = $job.Src
    if ($item.Cancel) { $item.State = 'Cancelled'; $item.Detail = ''; continue }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($src)
    $itemOut = $item.OutDir
    if (-not $itemOut) { $itemOut = $OutDir }
    $dst = Join-Path $itemOut ($name + '.mp4')
    # Work on a temporary name: a cancel or failure never touches an existing file,
    # and nobody opens a half-made file by mistake
    $tmp = Join-Path $itemOut ($name + '.converting.mp4')
    try {
        $sync.CvItem = $item.Id
        $item.State = 'Converting'; $item.Detail = 'Checking video...'
        $lane.Title = $item.Title; $lane.Status = 'Checking video...'; $lane.Percent = -1.0; $lane.Active = $true
        New-Item -ItemType Directory -Force -Path $itemOut | Out-Null
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

        $plan = Get-EditReadyPlan $src $tmp $BinDir
        if (-not $plan) {
            Log "Skipped (no video stream): $src"
            $item.State = 'Failed'; $item.Detail = 'No video in the download'
            continue
        }
        Log "Edit-ready ($name): $($plan.Summary)"
        $script:duration = $plan.Duration
        $script:engine = ''
        if ($plan.Summary -match 'NVIDIA GPU|tone-map: GPU') { $script:engine = ' on the graphics card' }
        $lane.Status = "Making edit-ready copy$($script:engine)..."
        if ($script:duration -gt 0) { $lane.Percent = 0.0 }
        $ffArgv = @('-hide_banner', '-loglevel', 'error', '-nostats', '-progress', 'pipe:1') + $plan.Args
        $fcode = @(Invoke-Tool $ffmpeg $ffArgv $onProgress 'Cv' $item)[-1]

        if ($fcode -ne 0 -and -not $item.Cancel -and -not $sync.Shutdown -and $plan.Fallback) {
            # Graphics card couldn't do it (driver, unsupported format...): do it on the CPU instead
            Log 'Graphics card conversion failed, retrying on the CPU...'
            Log "Edit-ready ($name): $($plan.Fallback.Summary)"
            $script:engine = ' on the CPU'
            $lane.Status = 'Retrying edit-ready copy on the CPU...'
            if ($script:duration -gt 0) { $lane.Percent = 0.0 }
            $ffArgv = @('-hide_banner', '-loglevel', 'error', '-nostats', '-progress', 'pipe:1') + $plan.Fallback.Args
            $fcode = @(Invoke-Tool $ffmpeg $ffArgv $onProgress 'Cv' $item)[-1]
        }

        if ($fcode -eq 0 -and -not $item.Cancel) {
            Move-Item -LiteralPath $tmp -Destination $dst -Force
            $item.State = 'Done'; $item.Detail = 'Done'; $item.Path = $dst
            Log "Saved: $dst"
            if (-not $item.KeepOriginal -and $src -ne $dst) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
        } else {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($item.Cancel) { $item.State = 'Cancelled'; $item.Detail = '' }
            else { $item.State = 'Failed'; $item.Detail = 'Conversion failed (see details)'; Log "Conversion failed: $src" }
        }
    } catch {
        Log "Error: $($_.Exception.Message)"
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if ($item.State -eq 'Converting') { $item.State = 'Failed'; $item.Detail = 'Conversion failed (see details)' }
    } finally {
        $sync.CvItem = ''; $sync.CvProc = 0
        $lane.Active = $false
    }
}
'@

# The window uses the shared helpers too (New-QueueItem, Stop-Tree)
. ([scriptblock]::Create($WorkerLib))

function Start-Worker([string]$Name, [string]$Body) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $script = "param(`$sync, `$AppDir, `$BinDir, `$OutDir, `$OrigDir, `$AllowFileUrls)`n" + $WorkerLib + "`n" + $Body
    [void]$ps.AddScript($script)
    [void]$ps.AddParameters(@{
        sync = $sync; AppDir = $AppDir; BinDir = $BinDir; OutDir = $OutDir; OrigDir = $OrigDir
        AllowFileUrls = ($env:MISFIT_DL_TEST_FILE_URLS -eq '1')
    })
    return @{ Name = $Name; Body = $Body; PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

$script:Workers = @()
function Start-Workers {
    if ($script:Workers.Count -eq 0) {
        $script:Workers = @((Start-Worker 'download' $DownloadLoop), (Start-Worker 'conversion' $ConvertLoop))
    }
}

# Restarts a lane if it ever stops unexpectedly, so the queue keeps moving
function Watch-Workers {
    if ($sync.Shutdown) { return }
    for ($i = 0; $i -lt $script:Workers.Count; $i++) {
        $w = $script:Workers[$i]
        if (-not $w.Handle.IsCompleted) { continue }
        try { $w.PS.EndInvoke($w.Handle) } catch { Add-Log ("Error: $($_.Exception.Message)") }
        foreach ($e in $w.PS.Streams.Error) { Add-Log ("Error: " + $e.ToString()) }
        $w.PS.Dispose(); $w.RS.Dispose()
        Add-Log "The $($w.Name) lane stopped unexpectedly and was restarted."
        $script:Workers[$i] = Start-Worker $w.Name $w.Body
    }
}

function Test-QueueBusy {
    foreach ($it in $sync.Items.ToArray()) { if ($ActiveStates -contains $it.State) { return $true } }
    return $false
}

function Update-DownloadButton {
    $ui.DownloadBtn.IsEnabled = (-not $script:Checking) -and $script:ToolsReady -and ((Get-Links).Count -gt 0)
    $ui.CheckBtn.IsEnabled = (-not $script:Checking) -and -not (Test-QueueBusy)
}

function Add-ToQueue {
    $links = Get-Links
    if ($links.Count -eq 0) { return }
    Save-Settings
    New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
    Start-Workers
    $editReady = [bool]$ui.EditReadyChk.IsChecked
    $keep = [bool]$ui.KeepOrigChk.IsChecked
    foreach ($l in $links) {
        $it = New-QueueItem $l $editReady $keep
        $it.OutDir = $script:OutDir; $it.OrigDir = $script:OrigDir
        [void]$sync.Items.Add($it)
        $sync.DlQueue.Enqueue($it)
    }
    $ui.UrlBox.Clear()
    Update-DownloadButton
}

# Cancels one item: waiting items are skipped, running ones have their tool stopped
function Stop-QueueItem($Item) {
    if ($ActiveStates -notcontains $Item.State) { return }
    $Item.Cancel = $true
    if ($sync.DlItem -eq $Item.Id) { Stop-Tree $sync.DlProc }
    elseif ($sync.CvItem -eq $Item.Id) { Stop-Tree $sync.CvProc }
    elseif ($Item.State -in 'Waiting', 'Waiting to convert') { $Item.State = 'Cancelled'; $Item.Detail = '' }
}

function Stop-AllItems {
    foreach ($it in $sync.Items.ToArray()) { Stop-QueueItem $it }
}

# ---------- Queue list on screen ----------
$script:Rows = @{}
$script:FailuresShown = @{}

function New-QueueRow($Item) {
    $grid = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)
    $title = New-Object System.Windows.Controls.TextBlock
    $title.TextTrimming = 'CharacterEllipsis'; $title.Margin = '0,0,14,0'
    $status = New-Object System.Windows.Controls.TextBlock
    [System.Windows.Controls.Grid]::SetColumn($status, 1)
    [void]$grid.Children.Add($title); [void]$grid.Children.Add($status)
    $li = New-Object System.Windows.Controls.ListBoxItem
    $li.Content = $grid
    $li.Tag = $Item.Id
    [void]$ui.QueueList.Items.Add($li)
    $ui.QueueList.ScrollIntoView($li)
    $row = @{ Item = $Item; Li = $li; Title = $title; Status = $status; Shown = '' }
    $script:Rows[$Item.Id] = $row
    return $row
}

function Get-StatusText($Item) {
    switch ($Item.State) {
        'Downloading' { if ($Item.Detail) { return $Item.Detail } else { return 'Downloading' } }
        'Converting'  { if ($Item.Detail) { return $Item.Detail } else { return 'Converting' } }
        'Failed'      { if ($Item.Detail) { return $Item.Detail } else { return 'Failed' } }
        default       { return $Item.State }
    }
}

function Update-QueueView {
    $counts = @{}
    foreach ($it in $sync.Items.ToArray()) {
        $counts[$it.State] = 1 + [int]$counts[$it.State]
        $row = $script:Rows[$it.Id]
        if (-not $row) { $row = New-QueueRow $it }
        $statusText = Get-StatusText $it
        $key = "$($it.Title)|$statusText|$($it.State)"
        if ($row.Shown -eq $key) { continue }
        $row.Shown = $key
        $row.Title.Text = $it.Title
        $row.Status.Text = $statusText
        switch ($it.State) {
            'Failed' {
                $row.Title.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Error')
                $row.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Error')
                if (-not $script:FailuresShown.ContainsKey($it.Id)) { $script:FailuresShown[$it.Id] = $true; Set-DetailsVisible $true }
            }
            'Cancelled' {
                $row.Title.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Faint')
                $row.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Faint')
            }
            'Done' {
                $row.Title.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Fg')
                $row.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
            }
            default {
                $row.Title.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Fg')
                $row.Status.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Body')
            }
        }
    }

    # Summary line: "2 waiting, 1 converting, 4 done"
    $parts = @()
    $waiting = [int]$counts['Waiting'] + [int]$counts['Waiting to convert']
    if ($waiting) { $parts += "$waiting waiting" }
    if ($counts['Downloading']) { $parts += 'downloading' }
    if ($counts['Converting']) { $parts += 'converting' }
    if ($counts['Done']) { $parts += "$($counts['Done']) done" }
    if ($counts['Failed']) { $parts += "$($counts['Failed']) failed" }
    $ui.QueueSummary.Text = ($parts -join ', ')

    $busy = Test-QueueBusy
    $sel = $null
    if ($ui.QueueList.SelectedItem) { $sel = $script:Rows[$ui.QueueList.SelectedItem.Tag] }
    $ui.CancelBtn.IsEnabled = [bool]($sel -and ($ActiveStates -contains $sel.Item.State) -and -not $sel.Item.Cancel)
    $ui.CancelAllBtn.IsEnabled = $busy
    $ui.ClearDoneBtn.IsEnabled = [bool]($counts['Done'] -or $counts['Failed'] -or $counts['Cancelled'])
    $ui.CheckBtn.IsEnabled = (-not $script:Checking) -and -not $busy
}

function Update-Lane($Lane, $TitleBox, $Bar, $StatusBox, [string]$IdleTitle, [string]$IdleStatus) {
    if ($Lane.Active) {
        $TitleBox.Text = $Lane.Title
        $StatusBox.Text = $Lane.Status
        if ($Lane.Percent -lt 0) { $Bar.IsIndeterminate = $true }
        else { $Bar.IsIndeterminate = $false; $Bar.Value = $Lane.Percent }
    } else {
        $TitleBox.Text = $IdleTitle
        $StatusBox.Text = $IdleStatus
        $Bar.IsIndeterminate = $false
        $Bar.Value = 0
    }
}

function Clear-Finished {
    foreach ($it in $sync.Items.ToArray()) {
        if ($ActiveStates -contains $it.State) { continue }
        $row = $script:Rows[$it.Id]
        if ($row) { $ui.QueueList.Items.Remove($row.Li); $script:Rows.Remove($it.Id) }
        $sync.Items.Remove($it)
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
$ui.DownloadBtn.Add_Click({ Add-ToQueue })
$ui.CancelBtn.Add_Click({
    $sel = $ui.QueueList.SelectedItem
    if ($sel -and $script:Rows[$sel.Tag]) { Stop-QueueItem $script:Rows[$sel.Tag].Item }
})
$ui.CancelAllBtn.Add_Click({
    $answer = [System.Windows.MessageBox]::Show('Cancel everything that is still waiting, downloading or converting?', $AppName, 'YesNo', 'Question')
    if ($answer -eq 'Yes') { Stop-AllItems }
})
$ui.ClearDoneBtn.Add_Click({ Clear-Finished })
$ui.ThemeBtn.Add_Click({
    if ($script:ThemeName -eq 'Dark') { Set-Theme 'Light' } else { Set-Theme 'Dark' }
    Save-Settings
})
$ui.DetailsBtn.Add_Click({ Set-DetailsVisible ($ui.LogBox.Visibility -ne 'Visible') })
$window.Add_SourceInitialized({ Set-TitleBarTheme })
$ui.CheckBtn.Add_Click({ if (-not (Test-QueueBusy) -and -not $script:Checking) { Start-UpdateCheck -Manual } })
$ui.OpenFolderBtn.Add_Click({
    New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null
    Start-Process explorer.exe -ArgumentList ('"' + $script:OutDir + '"')
})
$ui.ChangeFolderBtn.Add_Click({
    $folder = Select-OutputFolder
    if ($folder) { Set-OutputFolder $folder $false }
})
$ui.DefaultFolderBtn.Add_Click({ Set-OutputFolder $DefaultOutDir $true })
$ui.QueueList.Add_MouseDoubleClick({
    $sel = $ui.QueueList.SelectedItem
    if (-not $sel) { return }
    $row = $script:Rows[$sel.Tag]
    if ($row -and $row.Item.Path -and (Test-Path -LiteralPath $row.Item.Path)) {
        Start-Process explorer.exe -ArgumentList ('/select,"' + $row.Item.Path + '"')
    }
})
$ui.QueueList.Add_SelectionChanged({ Update-QueueView })

$window.Add_Closing({
    param($sender, $e)
    if (Test-QueueBusy) {
        $answer = [System.Windows.MessageBox]::Show('Videos are still in the queue. Stop them and close?', $AppName, 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        Stop-AllItems
    }
    $sync.Shutdown = $true
    Stop-Tree $sync.DlProc
    Stop-Tree $sync.CvProc
    if ($script:UpdProc -and -not $script:UpdProc.HasExited -and -not $script:ClosingForRestart) {
        try { $script:UpdProc.Kill() } catch { }
    }
})

# ---------- Timer: moves background progress onto the screen ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $line = $null
    while ($sync.Log.TryDequeue([ref]$line)) { Add-Log $line }

    $waitingDl = 0; $waitingCv = 0
    foreach ($it in $sync.Items.ToArray()) {
        if ($it.State -eq 'Waiting') { $waitingDl++ } elseif ($it.State -eq 'Waiting to convert') { $waitingCv++ }
    }
    $dlIdle = 'Add links above to start.'
    if ($waitingDl) { $dlIdle = 'Starting the next download...' }
    $cvIdle = ' '
    if ($waitingCv) { $cvIdle = 'Starting the next conversion...' }
    elseif ($sync.DlLane.Active -and [bool]$ui.EditReadyChk.IsChecked) { $cvIdle = 'Waiting for a download to finish.' }
    Update-Lane $sync.DlLane $ui.DlTitle $ui.DlBar $ui.DlStatus 'Nothing downloading' $dlIdle
    Update-Lane $sync.CvLane $ui.CvTitle $ui.CvBar $ui.CvStatus 'Nothing converting' $cvIdle
    Update-QueueView
    Watch-Workers

    if ($script:UpdProc) { Step-UpdateCheck }
    # Left open for a long time? Check again, but only while idle with no links typed in
    elseif (-not $script:Checking -and $ui.UrlBox.Text.Trim().Length -eq 0 -and -not (Test-QueueBusy) -and
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
    $ui.FolderText.Text = 'C:\Users\you\Downloads\Misfit Downloader'
    $sample = @(
        @{ Title = 'Behind the scenes [4K]'; State = 'Done'; Detail = 'Done' },
        @{ Title = 'Product launch teaser'; State = 'Converting'; Detail = 'Converting 42%' },
        @{ Title = 'Drone footage - city at night'; State = 'Downloading'; Detail = 'Downloading 67%' },
        @{ Title = 'https://vimeo.com/123456789'; State = 'Waiting'; Detail = '' }
    )
    foreach ($s in $sample) {
        $it = New-QueueItem 'https://example.com' $true $true
        $it.Title = $s.Title; $it.State = $s.State; $it.Detail = $s.Detail
        [void]$sync.Items.Add($it)
    }
    $sync.DlLane.Active = $true; $sync.DlLane.Title = 'Drone footage - city at night'
    $sync.DlLane.Status = 'Downloading video   67.0%   18.4MiB/s   ETA 00:21'; $sync.DlLane.Percent = 67
    $sync.CvLane.Active = $true; $sync.CvLane.Title = 'Product launch teaser'
    $sync.CvLane.Status = 'Making edit-ready copy on the graphics card   42.0%'; $sync.CvLane.Percent = 42
    Update-Lane $sync.DlLane $ui.DlTitle $ui.DlBar $ui.DlStatus '' ''
    Update-Lane $sync.CvLane $ui.CvTitle $ui.CvBar $ui.CvStatus '' ''
    Update-QueueView
    $root = $window.Content
    $window.Content = $null
    $host2 = New-Object System.Windows.Controls.Border
    $host2.Resources = $window.Resources
    $host2.Background = $window.Background
    # Text color and font are normally inherited from the window; give them to the stand-in host
    $host2.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'Fg')
    [System.Windows.Documents.TextElement]::SetFontFamily($host2, $window.FontFamily)
    [System.Windows.Documents.TextElement]::SetFontSize($host2, $window.FontSize)
    $host2.Child = $root
    $w = 760; $h = 900
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
    Show-OutputFolder
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

# Let the background lanes finish up (their tools were stopped when the window closed)
$sync.Shutdown = $true
foreach ($w in $script:Workers) {
    try { [void]$w.Handle.AsyncWaitHandle.WaitOne(5000) } catch { }
}
