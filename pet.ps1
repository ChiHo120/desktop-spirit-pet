# 桌面小灵宠：浮在 Windows 桌面上，显示这台电脑的实时传感器。
param(
    [switch]$SelfTest,
    [switch]$Shot,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib = Join-Path $root 'sensors.ps1'
. $lib
. (Join-Path $root 'state.ps1')
. (Join-Path $root 'workers.ps1')

if ($SelfTest) {
    $null = Get-SpiritSnapshot
    try { $null = Get-GpuBusyPercent } catch {}
    Start-Sleep -Seconds 1
    $snap = Get-SpiritSnapshot
    $gpu = $null
    try { $gpu = Get-GpuBusyPercent } catch { $gpu = $_.Exception.Message }
    Write-Output ('CPU={0}% {1}MHz' -f $snap.Cpu, $snap.CpuMhz)
    Write-Output ('RAM={0}/{1}GB {2}%' -f $snap.RamUsedGB, $snap.RamTotalGB, $snap.RamPct)
    Write-Output ('TEMP={0}C ZONE={1} PASSIVE={2}' -f $snap.TempC, $snap.TempZone, $snap.Passive)
    Write-Output ('DISK_BUSY={0} READ={1} WRITE={2}' -f $snap.DiskBusy, $snap.DiskRead, $snap.DiskWrite)
    foreach ($disk in $snap.Disks) {
        Write-Output ('DRIVE {0} {1}% free {2}GB' -f $disk.Name, $disk.UsedPct, $disk.FreeGB)
    }
    Write-Output ('DISK_TOTAL={0}% {1}/{2}GB' -f $snap.DiskUsedPct, $snap.DiskUsedGB, $snap.DiskTotalGB)
    Write-Output ('NET {0} wifi={1} vpn={2}' -f $snap.NetName, $snap.IpAddress, $snap.VpnOn)
    foreach ($vpnRow in @($snap.VpnRows)) {
        Write-Output ('VPNROW {0} {1} {2} {3}' -f $vpnRow.Label, $vpnRow.Kind, $vpnRow.Place, $vpnRow.Ip)
    }
    Write-Output ('BATTERY has={0} pct={1} ac={2} charging={3}' -f $snap.HasBattery, $snap.BatteryPct, $snap.OnAc, $snap.Charging)
    Write-Output ('GPU={0}' -f $gpu)
    Write-Output ('MACHINE={0} | {1} | {2}' -f $snap.MachineLine, $snap.CpuName, $snap.GpuName)
    return
}

if (-not ('SpiritNative.Dpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SpiritNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct WindowRect { public int Left, Top, Right, Bottom; }
    public static class Dpi {
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hwnd, out WindowRect rect);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);
    }
}
'@
}
try { [void][SpiritNative.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$instanceName = if ($SmokeTest) { 'Local\DesktopSpiritPet.Smoke.' + $PID } else { 'Local\DesktopSpiritPet.Ultra9' }
$activationName = $instanceName + '.Activate'
$createdNew = $false
$created = New-Object System.Threading.Mutex($false, $instanceName, [ref]$createdNew)
$eventCreated = $false
$activationEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, $activationName, [ref]$eventCreated)
$gotMutex = $false
try {
    $gotMutex = $created.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $gotMutex = $true
} catch {
    $gotMutex = $false
}
if (-not $gotMutex) {
    # A second launch asks the existing pet to return instead of doing nothing.
    try { $activationEvent.Set() } catch {}
    $activationEvent.Dispose()
    $created.Dispose()
    return
}

$stateDir = Join-Path $env:LOCALAPPDATA '桌面小灵宠'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
$statePath = Join-Path $stateDir 'window.json'
$logPath = Join-Path $stateDir 'log.txt'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) '桌面小灵宠.lnk'

function Write-PetLog {
    param([string]$Message)
    if (-not $SmokeTest) { Write-SpiritLog $logPath $Message }
}

$sync = [hashtable]::Synchronized(@{ Stop = $false; Snapshot = $null; GpuResult = $null; GeoResult = $null; GeoEnabled = $false; FastError = '' })
$workers = @()
$notify = $null
$timer = $null
$saveTimer = $null
# This outer finally covers initialization failures as well as normal window closure.
try {
$xaml = Get-Content -LiteralPath (Join-Path $root 'ui.xaml') -Raw -Encoding UTF8

$reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader $xaml))
try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }

$controls = @{}
function Find($name) {
    if (-not $controls.ContainsKey($name)) { $controls[$name] = $window.FindName($name) }
    return $controls[$name]
}

$card = Find 'Card'
$pet = Find 'Pet'
$petBob = Find 'PetBob'
$tailRotate = Find 'TailRotate'
$aura = Find 'Aura'
$crystal = Find 'Crystal'
$lidL = Find 'LidL'
$lidR = Find 'LidR'
$pupilL = Find 'PupilL'
$pupilR = Find 'PupilR'
$mouth = Find 'Mouth'
$zzz = Find 'Zzz'
$expanded = $true

function Set-ColorStop {
    param($name, $hex)
    $stop = Find $name
    if ($stop) { $stop.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex) }
}

function Set-Bar {
    param($name, [double]$percent)
    $bar = Find $name
    $clamped = [math]::Max(0, [math]::Min(100, $percent))
    $width = $bar.Parent.ActualWidth
    if ($width -le 0) { $width = 118 }
    $bar.Width = $width * ($clamped / 100.0)
}

function Format-Rate {
    param([double]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB/s' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB/s' -f ($Bytes / 1KB)) }
    return ('{0:N0} B/s' -f $Bytes)
}

function Set-Mood {
    param([string]$Kind)
    switch ($Kind) {
        'hot' {
            Set-ColorStop 'BodyC1' '#FF7A59'
            Set-ColorStop 'BodyC2' '#FFD166'
            Set-ColorStop 'TailC1' '#FF8A5B'
            Set-ColorStop 'TailC2' '#FFE08A'
            Set-ColorStop 'AuraC1' '#88FB7185'
            Set-ColorStop 'CrystalC' '#FF8B7A'
            $lidL.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FF7A59')
            $lidR.Fill = $lidL.Fill
            $mouth.Data = [System.Windows.Media.Geometry]::Parse('M 74,136 Q 84,128 94,136')
            $zzz.Opacity = 0
        }
        'busy' {
            Set-ColorStop 'BodyC1' '#6C5CE7'
            Set-ColorStop 'BodyC2' '#74B9FF'
            Set-ColorStop 'TailC1' '#6C5CE7'
            Set-ColorStop 'TailC2' '#81ECEC'
            Set-ColorStop 'AuraC1' '#887C6CFF'
            Set-ColorStop 'CrystalC' '#A29BFE'
            $lidL.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#6C5CE7')
            $lidR.Fill = $lidL.Fill
            $mouth.Data = [System.Windows.Media.Geometry]::Parse('M 76,134 Q 84,140 92,134')
            $zzz.Opacity = 0
        }
        'sleep' {
            Set-ColorStop 'BodyC1' '#5B6B8A'
            Set-ColorStop 'BodyC2' '#8EC5FF'
            Set-ColorStop 'TailC1' '#6C7A99'
            Set-ColorStop 'TailC2' '#B7D7FF'
            Set-ColorStop 'AuraC1' '#448EC5FF'
            Set-ColorStop 'CrystalC' '#D6E6FF'
            $lidL.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#5B6B8A')
            $lidR.Fill = $lidL.Fill
            $mouth.Data = [System.Windows.Media.Geometry]::Parse('M 76,136 L 92,136')
            $zzz.Text = 'z'
            $zzz.Opacity = 0.9
        }
        default {
            Set-ColorStop 'BodyC1' '#6D5EF5'
            Set-ColorStop 'BodyC2' '#49D6FF'
            Set-ColorStop 'TailC1' '#8B7CFF'
            Set-ColorStop 'TailC2' '#5CE1FF'
            Set-ColorStop 'AuraC1' '#8867E8F9'
            Set-ColorStop 'CrystalC' '#7AF0FF'
            $lidL.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#6D5EF5')
            $lidR.Fill = $lidL.Fill
            $mouth.Data = [System.Windows.Media.Geometry]::Parse('M 72,132 Q 84,144 96,132')
            $zzz.Opacity = 0
        }
    }
}

function Set-WindowVisible {
    param([bool]$Show)
    if ($Show) {
        $script:hidden = $false
        $window.Visibility = 'Visible'
        $window.ShowInTaskbar = $true
        $window.WindowState = 'Normal'
        [void]$window.Activate()
        if (-not (Test-OnScreen)) { Move-ToCorner }
    } else {
        $script:hidden = $true
        $window.Visibility = 'Hidden'
        $window.ShowInTaskbar = $false
    }
}

function Set-Expanded {
    param([bool]$Show)
    $script:expanded = $Show
    if ($Show) {
        $card.Visibility = 'Visible'
        (Find 'MenuPanel').Header = '收起数据'
        (Find 'FootText').Text = '点小灵收起，右键设置；Ctrl + 滚轮缩放'
    } else {
        $card.Visibility = 'Collapsed'
        (Find 'MenuPanel').Header = '展开数据'
    }
}

$settings = if ($SmokeTest) { Read-SpiritState '' } else { Read-SpiritState $statePath }
$sync.GeoEnabled = [bool]$settings.GeoEnabled
(Find 'MenuGeo').IsChecked = $settings.GeoEnabled
(Find 'MenuMotion').IsChecked = $settings.ReducedMotion
(Find 'MenuPrivacy').IsChecked = [bool]$settings.PrivacyMode

$window.Topmost = [bool]$settings.Topmost
(Find 'MenuTopmost').IsChecked = $window.Topmost
Set-Expanded ([bool]$settings.Expanded)

$script:scale = 0.72
$script:scaleLock = $false
function Set-PetScale {
    param([double]$Value)
    $Value = [math]::Round($Value, 2)
    if ($Value -lt 0.45) { $Value = 0.45 }
    if ($Value -gt 1.4) { $Value = 1.4 }
    $script:scale = $Value
    $rootScale = Find 'RootScale'
    $rootScale.ScaleX = $Value
    $rootScale.ScaleY = $Value
    $pct = [int][math]::Round($Value * 100, 0)
    (Find 'SizeVal').Text = ('{0}%' -f $pct)
    $slider = Find 'SizeSlider'
    if ([math]::Abs($slider.Value - $pct) -ge 1) {
        $script:scaleLock = $true
        $slider.Value = $pct
        $script:scaleLock = $false
    }
}

function Save-State {
    param([switch]$Immediate)
    if ($SmokeTest) { return }
    if (-not $Immediate) { $saveTimer.Stop(); $saveTimer.Start(); return }
    $saveTimer.Stop()
    $payload = @{
        Left = [math]::Round($window.Left, 1); Top = [math]::Round($window.Top, 1)
        Topmost = [bool]$window.Topmost; Expanded = [bool]$script:expanded; Scale = $script:scale
        GeoEnabled = [bool]$sync.GeoEnabled; ReducedMotion = [bool](Find 'MenuMotion').IsChecked; PrivacyMode = [bool](Find 'MenuPrivacy').IsChecked
    }
    try { Write-SpiritState $statePath $payload }
    catch { Write-PetLog ('保存设置失败: ' + $_.Exception.Message) }
}
$saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$saveTimer.Interval = [timespan]::FromMilliseconds(400)
$saveTimer.Add_Tick({ Save-State -Immediate })

function Set-WindowPixelPosition {
    param([IntPtr]$Handle, [int]$X, [int]$Y)
    # WPF uses DIPs; Win32 and Screen.WorkingArea use physical pixels. Keep them separate.
    [void][SpiritNative.Dpi]::SetWindowPos($Handle, [IntPtr]::Zero, $X, $Y, 0, 0, 0x0015)
}
function Move-ToCorner {
    $window.UpdateLayout()
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
    $area = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
    $rect = New-Object SpiritNative.WindowRect
    if (-not [SpiritNative.Dpi]::GetWindowRect($hwnd, [ref]$rect)) { return }
    $x = [math]::Max($area.Left, $area.Right - ($rect.Right - $rect.Left) - 28)
    $y = [math]::Max($area.Top, $area.Bottom - ($rect.Bottom - $rect.Top) - 24)
    Set-WindowPixelPosition $hwnd $x $y
}
function Test-OnScreen {
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    if ($hwnd -eq [IntPtr]::Zero) { return $true }
    $rect = New-Object SpiritNative.WindowRect
    if (-not [SpiritNative.Dpi]::GetWindowRect($hwnd, [ref]$rect)) { return $false }
    $bounds = [System.Drawing.Rectangle]::FromLTRB($rect.Left,$rect.Top,$rect.Right,$rect.Bottom)
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $overlap = [System.Drawing.Rectangle]::Intersect($screen.WorkingArea, $bounds)
        if ($overlap.Width -ge 32 -and $overlap.Height -ge 32) { return $true }
    }
    return $false
}
function Keep-OnScreen {
    if (-not $window.IsLoaded) { return }
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $rect = New-Object SpiritNative.WindowRect
    if (-not [SpiritNative.Dpi]::GetWindowRect($hwnd, [ref]$rect)) { return }
    $area = [System.Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
    $x = [math]::Max($area.Left, [math]::Min($rect.Left, $area.Right - ($rect.Right-$rect.Left)))
    $y = [math]::Max($area.Top, [math]::Min($rect.Top, $area.Bottom - ($rect.Bottom-$rect.Top)))
    if ($x -ne $rect.Left -or $y -ne $rect.Top) { Set-WindowPixelPosition $hwnd $x $y }
}
$window.Add_SizeChanged({ Keep-OnScreen })

$pointer = @{ Down = $false; Dragged = $false; X = 0; Y = 0 }
$anim = @{ Tick = 0; Blink = 0; NextBlink = 90; Mood = '' }
$diskStamp = ''
$script:vpnStamp = ''

. (Join-Path $root 'icons.ps1')

$window.Add_PreviewMouseLeftButtonDown({
    $src = $_.OriginalSource -as [System.Windows.DependencyObject]
    $node = $src
    while ($node) {
        if ($node -is [System.Windows.Controls.Button] -or $node -is [System.Windows.Controls.Slider] -or $node -is [System.Windows.Controls.Primitives.Thumb] -or $node -is [System.Windows.Controls.Primitives.Track]) { return }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    $pointer.Down = $true
    $pointer.Dragged = $false
    $pos = $_.GetPosition($window)
    $pointer.X = $pos.X
    $pointer.Y = $pos.Y
})

$window.Add_PreviewMouseMove({
    if (-not $pointer.Down) { return }
    if ($_.LeftButton -ne [System.Windows.Input.MouseButtonState]::Pressed) { return }
    $pos = $_.GetPosition($window)
    if ([math]::Abs($pos.X - $pointer.X) -gt 6 -or [math]::Abs($pos.Y - $pointer.Y) -gt 6) {
        $pointer.Dragged = $true
        $pointer.Down = $false
        try { $window.DragMove() } catch {}
        Keep-OnScreen
        Save-State
    }
})

function Test-Inside {
    param($Source, $name)
    $node = $Source -as [System.Windows.DependencyObject]
    $target = Find $name
    while ($node) {
        if ($node -eq $target) { return $true }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $false
}

$script:diskOpen = $false
$window.Add_PreviewMouseLeftButtonUp({
    if ($pointer.Down -and -not $pointer.Dragged) {
        if (Test-Inside $_.OriginalSource 'DiskRow') {
            $script:diskOpen = -not $script:diskOpen
            if ($script:diskOpen) { (Find 'DiskHost').Visibility = 'Visible' }
            else { (Find 'DiskHost').Visibility = 'Collapsed' }
            $script:diskStamp = ''
        } elseif (Test-Inside $_.OriginalSource 'Pet') {
            $script:replyUntil = [datetime]::UtcNow.AddSeconds(3)
            (Find 'PetReply').Text = '我在呢！'
            (Find 'PetReply').Visibility = 'Visible'
            Set-Expanded (-not $script:expanded)
            Save-State
        }
    }
    $pointer.Down = $false
})

(Find 'CloseBtn').Add_Click({ Set-WindowVisible $false; Save-State })
(Find 'MenuHide').Add_Click({ Set-WindowVisible $false; Save-State })
(Find 'MenuExit').Add_Click({ $window.Close() })
(Find 'MenuPanel').Add_Click({ Set-Expanded (-not $script:expanded); Save-State })
(Find 'MenuSmaller').Add_Click({ Set-PetScale ($script:scale - 0.08); Save-State })
(Find 'MenuLarger').Add_Click({ Set-PetScale ($script:scale + 0.08); Save-State })
(Find 'SizeSlider').Add_ValueChanged({
    if ($script:scaleLock) { return }
    Set-PetScale ((Find 'SizeSlider').Value / 100.0)
    Save-State
})
$window.Add_PreviewMouseWheel({
    if (-not ($_.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { return }
    $step = 0.06
    if ($_.Delta -lt 0) { $step = -0.06 }
    Set-PetScale ($script:scale + $step)
    Save-State
    $_.Handled = $true
})
Set-PetScale ([double]$settings.Scale)
(Find 'MenuTopmost').Add_Click({
    $window.Topmost = [bool](Find 'MenuTopmost').IsChecked
    Save-State
})
(Find 'MenuPrivacy').Add_Click({ Save-State })
(Find 'MenuGeo').Add_Click({
    $sync.GeoEnabled = [bool](Find 'MenuGeo').IsChecked
    if (-not $sync.GeoEnabled) { $sync.GeoResult = $null }
    Save-State
})
(Find 'MenuMotion').Add_Click({
    if ((Find 'MenuMotion').IsChecked) { $lidL.Opacity = 0; $lidR.Opacity = 0; $petBob.Y = 0 }
    Save-State
})
(Find 'MenuReset').Add_Click({ Set-PetScale 0.72; Set-Expanded $true; Move-ToCorner; Set-WindowVisible $true; Save-State })
(Find 'MenuStartup').Add_Click({
    $menu = Find 'MenuStartup'
    try {
        if ($menu.IsChecked) {
            $shell = New-Object -ComObject WScript.Shell
            try {
                $link = $shell.CreateShortcut($startupLink)
                $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $link.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'pet.ps1')
                $link.WorkingDirectory = $root
                $link.WindowStyle = 7
                $link.Description = '桌面小灵宠'
                $link.Save()
            } finally {
                if ($link) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($link) }
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
            }
        } elseif (Test-Path -LiteralPath $startupLink) {
            Remove-Item -LiteralPath $startupLink -Force -ErrorAction Stop
        }
    } catch {
        Write-PetLog ('开机启动设置失败: ' + $_.Exception.Message)
        [void][System.Windows.MessageBox]::Show('未能修改开机启动设置，请检查启动文件夹权限。', '桌面小灵宠')
    }
    $menu.IsChecked = Test-Path -LiteralPath $startupLink
})
(Find 'MenuStartup').IsChecked = Test-Path $startupLink

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
    if ($activationEvent.WaitOne(0)) { Set-WindowVisible $true }
    if ($script:replyUntil -and [datetime]::UtcNow -ge $script:replyUntil) { (Find 'PetReply').Visibility = 'Collapsed' }
    $anim.Tick++
    if ($window.IsVisible -and -not (Find 'MenuMotion').IsChecked -and $window.WindowState -ne 'Minimized') {
    $petBob.Y = [math]::Sin($anim.Tick / 14.0) * 4
    $tailRotate.Angle = 16 + ([math]::Sin($anim.Tick / 9.0) * 14)
    $crystal.Opacity = 0.75 + ([math]::Sin($anim.Tick / 8.0) * 0.25)
    $aura.Opacity = 0.38 + ([math]::Sin($anim.Tick / 18.0) * 0.12)
    $look = [math]::Sin($anim.Tick / 40.0) * 2
    [System.Windows.Controls.Canvas]::SetLeft($pupilL, 60 + $look)
    [System.Windows.Controls.Canvas]::SetLeft($pupilR, 100 + $look)

    if ($anim.Blink -gt 0) {
        $anim.Blink--
        $lidL.Opacity = 1
        $lidR.Opacity = 1
    } else {
        $lidL.Opacity = 0
        $lidR.Opacity = 0
        $anim.NextBlink--
        if ($anim.NextBlink -le 0) {
            $anim.Blink = 5
            $anim.NextBlink = Get-Random -Minimum 70 -Maximum 160
        }
    }

    }
    $now = [datetime]::UtcNow
    if (-not $window.IsVisible -or (Find 'MenuMotion').IsChecked -or $window.WindowState -eq 'Minimized') { $timer.Interval = [timespan]::FromMilliseconds(500) }
    else { $timer.Interval = [timespan]::FromMilliseconds(33) }
    if ($script:lastUiAt -and ($now - $script:lastUiAt).TotalMilliseconds -lt 490) { return }
    $script:lastUiAt = $now
    if ($window.IsVisible -and $window.WindowState -ne 'Minimized' -and (-not $script:lastScreenAt -or ($now - $script:lastScreenAt).TotalSeconds -ge 5)) {
        $script:lastScreenAt = $now
        if (-not (Test-OnScreen)) { Move-ToCorner }
    }
    $snapshot = $sync.Snapshot
    if (-not $snapshot) {
        if ($sync.FastError) { (Find 'StatusText').Text = '传感器初始化失败，正在重试' }
        return
    }
    $stale = (([datetime]::UtcNow - $snapshot.SampledAt).TotalSeconds -gt 10) -or [bool]$sync.FastError
    $status = Find 'StatusText'
    $status.Text = if ($stale) { '数据已过期，正在重试' } elseif ($snapshot.SensorErrors.Count -gt 0 -or $snapshot.Error) { '部分传感器暂不可用' } else { '更新于 ' + $snapshot.SampledAt.ToLocalTime().ToString('HH:mm:ss') }
    $status.Foreground = if ($stale) { [Windows.Media.Brushes]::OrangeRed } else { [Windows.Media.Brushes]::Gray }
    if ($sync.FastError -and $script:lastLoggedError -ne $sync.FastError) { Write-PetLog ('采样失败: ' + $sync.FastError) }
    $script:lastLoggedError = $sync.FastError
    $status.ToolTip = if ($sync.FastError) { $sync.FastError } else { (@($snapshot.SensorErrors.Values) -join [Environment]::NewLine) }


    $cpu = [double]$snapshot.Cpu
    $ramPct = [double]$snapshot.RamPct
    $temp = $snapshot.TempC
    $mood = 'calm'
    $gpuForMood = $sync.GpuResult
    $gpuBusy = ($gpuForMood -and $null -ne $gpuForMood.Value -and [double]$gpuForMood.Value -ge 55)
    if ($null -ne $temp -and [double]$temp -ge 80) { $mood = 'hot' }
    elseif ($cpu -ge 55 -or $ramPct -ge 85 -or $gpuBusy) { $mood = 'busy' }
    elseif ($null -ne $snapshot.Cpu -and $cpu -lt 8 -and ($null -eq $temp -or [double]$temp -lt 70)) { $mood = 'sleep' }
    if ($anim.Mood -ne $mood) {
        $anim.Mood = $mood
        Set-Mood $mood
    }

    if ($stale) { Set-Mood 'calm'; $anim.Mood = 'calm' }
    $moodLabel = '在桌面上发呆'
    if ($mood -eq 'hot') { $moodLabel = '有点热，我想吹吹风' }
    elseif ($mood -eq 'busy') { $moodLabel = if ($gpuBusy -and $cpu -lt 55) { '显卡正在忙' } elseif ($ramPct -ge 85) { '内存有些紧张' } else { '这台电脑正在忙' } }
    elseif ($mood -eq 'sleep') { $moodLabel = '好安静，我打个盹' }
    (Find 'MoodText').Text = $moodLabel
    (Find 'MachineText').Text = '{0} · {1}' -f $snapshot.CpuName, $snapshot.UptimeText

    $cpuText = '{0:N0}%' -f $cpu
    if ($snapshot.CpuMhz) { $cpuText = '{0:N0}% · {1:N1} GHz' -f $cpu, ([double]$snapshot.CpuMhz / 1000) }
    (Find 'CpuVal').Text = $cpuText
    Set-Bar 'CpuBar' $cpu

    (Find 'RamVal').Text = '{0:N1}/{1:N1} GB' -f [double]$snapshot.RamUsedGB, [double]$snapshot.RamTotalGB
    Set-Bar 'RamBar' $ramPct

    $diskPct = 0.0
    if ($null -ne $snapshot.DiskUsedPct) { $diskPct = [double]$snapshot.DiskUsedPct }
    $diskMark = '›'
    if ($script:diskOpen) { $diskMark = '⌄' }
    $diskText = ('{0:N0}% {1}' -f $diskPct, $diskMark)
    if ($snapshot.PrimaryDisk -and $null -ne $snapshot.PrimaryDiskFreeGB) {
        $diskText = ('{0} 剩余 {1:N1} GB' -f $snapshot.PrimaryDisk, $snapshot.PrimaryDiskFreeGB)
        if ($snapshot.DiskAlert) { $diskText += ' · 快满' }
    }
    (Find 'DiskVal').Text = $diskText
    Set-Bar 'DiskBar' $diskPct
    if ($script:diskOpen) {
        $rows = @($snapshot.Disks)
        $stamp = (($rows | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Name, $_.UsedPct, $_.FreeGB, $_.SizeGB }) -join '|')
        if ($stamp -ne $diskStamp) {
            $script:diskStamp = $stamp
            $hostPanel = Find 'DiskHost'
            $hostPanel.Children.Clear()
            foreach ($disk in $rows) {
                $line = New-Object System.Windows.Controls.TextBlock
                $line.Text = '{0}  已用 {1}% · 剩余 {2} GB / {3} GB' -f $disk.Name, $disk.UsedPct, $disk.FreeGB, $disk.SizeGB
                $line.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#8EA0B8')
                $line.FontSize = 11
                $line.Margin = '0,1,0,0'
                [void]$hostPanel.Children.Add($line)
            }
        }
    }

    if ($null -eq $temp) {
        (Find 'TempVal').Text = '无读数'
        Set-Bar 'TempBar' 0
        (Find 'TempHint').Text = '这台机器没有返回热区温度'
    } else {
        (Find 'TempVal').Text = '{0:N1} °C' -f [double]$temp
        $tempPct = (([double]$temp - 35) / 60) * 100
        Set-Bar 'TempBar' $tempPct
        $zone = [string]$snapshot.TempZone
        if (-not $zone) { $zone = 'THM0' }
        $hint = '固件热区 {0}' -f $zone
        if ($null -ne $snapshot.Passive -and [double]$snapshot.Passive -lt 99) {
            $hint = '{0} · 正在温控降频' -f $hint
        }
        (Find 'TempHint').Text = $hint
    }

    $gpu = $sync.GpuResult
    if ($gpu -and $null -ne $gpu.Value -and ([datetime]::UtcNow - $gpu.At).TotalSeconds -lt 15 -and -not $gpu.Error) {
        (Find 'GpuVal').Text = '{0:N0}%' -f $gpu.Value
        Set-Bar 'GpuBar' $gpu.Value
    } else {
        (Find 'GpuVal').Text = if ($gpu -and $gpu.Error) { '暂不可用' } elseif ($gpu) { '暂无读数' } else { '等待采样' }
        Set-Bar 'GpuBar' 0
    }
    (Find 'GpuHint').Text = '所有 GPU 中最忙的引擎'
    (Find 'GpuHint').ToolTip = if ((Find 'MenuPrivacy').IsChecked) { '设备信息已隐藏' } else { [string]$snapshot.GpuName }
    (Find 'GpuVal').ToolTip = if ($gpu) { $gpu.Error } else { 'GPU 首次采样可能需要数秒' }

    $downText = Format-Rate ([double]$snapshot.NetDown)
    $upText = Format-Rate ([double]$snapshot.NetUp)
    $netBytes = [double]$snapshot.NetDown + [double]$snapshot.NetUp
    (Find 'NetVal').Text = ('↓ {0}  ↑ {1}' -f $downText, $upText)
    $netHint = if ($snapshot.NetName) { [string]$snapshot.NetName } else { '当前传输速率' }
    (Find 'NetHint').Text = $netHint
    (Find 'IpLabel').Text = $snapshot.IpLabel
    if ((Find 'MenuPrivacy').IsChecked) { (Find 'IpVal').Text = '已隐藏'; (Find 'MachineText').Text = '设备信息已隐藏' }
    elseif ($snapshot.IpAddress) { (Find 'IpVal').Text = [string]$snapshot.IpAddress }
    else { (Find 'IpVal').Text = '未连接' }
    $vpnRows = if ((Find 'MenuPrivacy').IsChecked) { @() } else { @($snapshot.VpnRows | Where-Object { $sync.GeoEnabled -or $_.Label -ne '上网' }) }
    $vpnStamp = (($vpnRows | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Label, $_.Ip, $_.Place, $_.Code }) -join ';')
    if ($vpnStamp -ne $script:vpnStamp) {
        $script:vpnStamp = $vpnStamp
        $vpnHost = Find 'VpnHost'
        $vpnHost.Children.Clear()
        if (-not $snapshot.VpnOn -or $vpnRows.Count -eq 0) {
            $vpnHost.Visibility = 'Collapsed'
        } else {
            $vpnHost.Visibility = 'Visible'
            $rowIndex = 0
            foreach ($vpnRow in $vpnRows) {
                $line = New-Object System.Windows.Controls.Grid
                if ($rowIndex -gt 0) { $line.Margin = '0,6,0,0' }
                $rowIndex++
                $c0 = New-Object System.Windows.Controls.ColumnDefinition
                $c0.Width = [System.Windows.GridLength]::new(46)
                $c1 = New-Object System.Windows.Controls.ColumnDefinition
                $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
                [void]$line.ColumnDefinitions.Add($c0)
                [void]$line.ColumnDefinitions.Add($c1)
                $label = New-Object System.Windows.Controls.TextBlock
                $label.Text = [string]$vpnRow.Label
                $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D5DEEA')
                $label.VerticalAlignment = 'Center'
                [void]$line.Children.Add($label)
                $pack = New-Object System.Windows.Controls.StackPanel
                $pack.Orientation = 'Horizontal'
                $pack.HorizontalAlignment = 'Right'
                [System.Windows.Controls.Grid]::SetColumn($pack, 1)
                $iconBorder = New-Object System.Windows.Controls.Border
                $iconBorder.Width = 22
                $iconBorder.Height = 15
                $iconBorder.Margin = '0,0,6,0'
                $iconBorder.CornerRadius = '1'
                $iconBorder.ClipToBounds = $true
                $iconBorder.VerticalAlignment = 'Center'
                $icon = New-Object System.Windows.Controls.Canvas
                $iconBorder.Child = $icon
                Draw-PlaceIcon $icon ([string]$vpnRow.Code) ([string]$vpnRow.Kind)
                $place = New-Object System.Windows.Controls.TextBlock
                $place.Text = [string]$vpnRow.Place
                $place.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D6E4F5')
                $place.FontSize = 12
                $place.Margin = '0,0,8,0'
                $place.VerticalAlignment = 'Center'
                $ipText = New-Object System.Windows.Controls.TextBlock
                $ipText.Text = [string]$vpnRow.Ip
                $ipText.Foreground = [System.Windows.Media.Brushes]::White
                $ipText.VerticalAlignment = 'Center'
                [void]$pack.Children.Add($iconBorder)
                [void]$pack.Children.Add($place)
                [void]$pack.Children.Add($ipText)
                [void]$line.Children.Add($pack)
                [void]$vpnHost.Children.Add($line)
            }
        }
    }

    if ($snapshot.HasBattery) {
        (Find 'BatteryRow').Visibility = 'Visible'
        $pct = [double]$snapshot.BatteryPct
        Set-Bar 'BatBar' $pct
        if ($snapshot.Charging) { $batText = '充电 {0:N0}%' -f $pct }
        elseif (-not $snapshot.OnAc) { $batText = '放电 {0:N0}%' -f $pct }
        else { $batText = '电源 {0:N0}%' -f $pct }
        (Find 'BatVal').Text = $batText
    } else {
        (Find 'BatteryRow').Visibility = 'Collapsed'
    }

    # Missing rates must not look like a genuine zero load.
    foreach ($item in @(@('Cpu','CpuVal','CpuBar'), @('RamPct','RamVal','RamBar'), @('DiskUsedPct','DiskVal','DiskBar'), @('NetDown','NetVal',''))) {
        if ($stale -or $null -eq $snapshot[$item[0]]) {
            (Find $item[1]).Text = if ($stale) { '已过期' } else { '暂无读数' }
            if ($item[2]) { Set-Bar $item[2] 0 }
        }
    }
    if ($stale) {
        (Find 'TempVal').Text = '已过期'
        Set-Bar 'TempBar' 0
        (Find 'NetHint').Text = '等待新采样'
        (Find 'BatVal').Text = '已过期'
        (Find 'MoodText').Text = '等一等，我再看看'
    }
    if ($stale) { (Find 'VpnHost').Visibility = 'Collapsed'; $script:vpnStamp = '' }

    if ($Shot -and -not $script:ShotDone -and $null -ne $snapshot.Cpu) {
        $script:ShotDone = $true
        $window.UpdateLayout()
        $width = [int][math]::Ceiling($window.ActualWidth)
        $height = [int][math]::Ceiling($window.ActualHeight)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $width, $height, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($window.Content)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $shotPath = Join-Path $root 'preview.png'
        $stream = [System.IO.File]::Open($shotPath, 'Create')
        try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
})
$timer.Start()

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = '桌面小灵宠'
$notify.Visible = $true
$notify.ContextMenuStrip = New-Object System.Windows.Forms.ContextMenuStrip
$trayShow = $notify.ContextMenuStrip.Items.Add('显示小灵')
$trayHide = $notify.ContextMenuStrip.Items.Add('隐藏小灵')
$trayExit = $notify.ContextMenuStrip.Items.Add('退出')
$trayShow.Add_Click({ Set-WindowVisible $true })
$trayHide.Add_Click({ Set-WindowVisible $false; Save-State })
$trayExit.Add_Click({ $script:allowExit = $true; $window.Close() })
$notify.Add_DoubleClick({ Set-WindowVisible $true })


$window.Add_ContentRendered({
    if ($null -ne $settings.Left -and $null -ne $settings.Top) {
        $window.Left = [double]$settings.Left
        $window.Top = [double]$settings.Top
        if (-not (Test-OnScreen)) { Move-ToCorner }
    } else {
        Move-ToCorner
    }
    Save-State
})

$window.Add_Closed({
    $timer.Stop()
    Save-State -Immediate
    $sync.Stop = $true
    try { $activationEvent.Dispose() } catch {}
})

foreach ($kind in @('Fast','Gpu','Geo')) { $workers += Start-SpiritWorker $sync $lib $kind }
if ($SmokeTest) {
    $sync.GeoEnabled = $false
    $window.Opacity = 0
    $window.ShowInTaskbar = $false
    $notify.Visible = $false
    $smokeTimer = New-Object System.Windows.Threading.DispatcherTimer
    $smokeTimer.Interval = [timespan]::FromSeconds(20)
    $smokeTimer.Add_Tick({
        $smokeTimer.Stop()
        try {
            Set-WindowVisible $false
            if ($window.IsVisible) { throw 'Hide failed' }
            Set-WindowVisible $true
            if (-not $window.IsVisible) { throw 'Restore failed' }
            [void]$activationEvent.Set()
            if (-not $activationEvent.WaitOne(0)) { throw 'Activation signal failed' }
            Set-PetScale 0
            if ($script:scale -ne 0.45) { throw 'Minimum scale clamp failed' }
            Set-PetScale 10
            if ($script:scale -ne 1.4) { throw 'Maximum scale clamp failed' }
            Set-Expanded $false
            $window.UpdateLayout()
            if ($card.Visibility -ne 'Collapsed') { throw 'Panel collapse failed' }
            Set-PetScale 0.72
            Set-Expanded $true
            $window.UpdateLayout()
            Keep-OnScreen
            if ($card.Visibility -ne 'Visible' -or -not (Test-OnScreen)) { throw 'Panel recovery failed' }
            if ($window.ActualWidth -le 0 -or $window.ActualHeight -le 0) { throw 'Invalid window layout' }
        } catch { $script:smokeFailure = $_.Exception.Message }
        finally { $window.Close() }
    })
    $smokeTimer.Start()
}
$application = New-Object System.Windows.Application
$application.ShutdownMode = 'OnMainWindowClose'
$null = $application.Run($window)
if ($SmokeTest) {
    if ($script:smokeFailure) { throw ('Smoke test: ' + $script:smokeFailure) }
    if (-not $sync.Snapshot -or $sync.FastError) { throw 'Smoke test: no valid sensor snapshot.' }
    Write-Output ('SMOKE PASS: cpuKnown={0}, gpuKnown={1}' -f ($null -ne $sync.Snapshot.Cpu), ($null -ne $sync.GpuResult.Value))
}
} catch {
    Write-PetLog $_.Exception.ToString()
    throw
} finally {
    if ($timer) { $timer.Stop() }
    if ($saveTimer) { $saveTimer.Stop() }
    if ($smokeTimer) { $smokeTimer.Stop() }
    if ($notify) { $notify.Visible = $false; $notify.Dispose() }
    Stop-SpiritWorkers $workers $sync
    try { $created.ReleaseMutex() } catch {}
    $created.Dispose()
    $activationEvent.Dispose()
}
