# 桌面小灵宠：浮在 Windows 桌面上，显示这台电脑的实时传感器。
param(
    [switch]$SelfTest,
    [switch]$Shot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$lib = Join-Path $root 'sensors.ps1'
. $lib

if ($SelfTest) {
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
    public static class Dpi {
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

$createdNew = $false
$created = New-Object System.Threading.Mutex($false, 'Local\DesktopSpiritPet.Ultra9', [ref]$createdNew)
$gotMutex = $false
try {
    $gotMutex = $created.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $gotMutex = $true
} catch {
    $gotMutex = $false
}
if (-not $gotMutex) { return }

$stateDir = Join-Path $env:LOCALAPPDATA '桌面小灵宠'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
$statePath = Join-Path $stateDir 'window.json'
$logPath = Join-Path $stateDir 'log.txt'
$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) '桌面小灵宠.lnk'

function Write-PetLog {
    param([string]$Message)
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

$sync = [hashtable]::Synchronized(@{
    Stop = $false
    Ready = $false
    Gpu = $null
    GpuKnown = $false
})

$fast = [powershell]::Create()
$fastRs = [runspacefactory]::CreateRunspace()
$fastRs.Open()
$fast.Runspace = $fastRs
[void]$fast.AddScript({
    param($sync, $lib)
    . $lib
    while (-not $sync.Stop) {
        try {
            $snap = Get-SpiritSnapshot
            foreach ($key in @($snap.Keys)) { $sync[$key] = $snap[$key] }
            $sync.Ready = $true
            $sync.FastError = ''
        } catch {
            $sync.FastError = $_.Exception.Message
        }
    }
}).AddArgument($sync).AddArgument($lib)
$fastHandle = $fast.BeginInvoke()

$gpuPs = [powershell]::Create()
$gpuRs = [runspacefactory]::CreateRunspace()
$gpuRs.Open()
$gpuPs.Runspace = $gpuRs
[void]$gpuPs.AddScript({
    param($sync, $lib)
    . $lib
    while (-not $sync.Stop) {
        try {
            $sync.Gpu = Get-GpuBusyPercent
            $sync.GpuKnown = $true
            $sync.GpuError = ''
        } catch {
            $sync.GpuError = $_.Exception.Message
        }
        $waited = 0
        while (-not $sync.Stop -and $waited -lt 30) {
            Start-Sleep -Milliseconds 100
            $waited++
        }
    }
}).AddArgument($sync).AddArgument($lib)
$gpuHandle = $gpuPs.BeginInvoke()

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="桌面小灵宠"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        ShowInTaskbar="True"
        SizeToContent="WidthAndHeight"
        ResizeMode="NoResize"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        FontFamily="Microsoft YaHei UI">
    <Window.ContextMenu>
        <ContextMenu>
            <MenuItem x:Name="MenuPanel" Header="收起数据"/>
            <MenuItem x:Name="MenuSmaller" Header="缩小"/>
            <MenuItem x:Name="MenuLarger" Header="放大"/>
            <MenuItem x:Name="MenuTopmost" Header="始终在最前" IsCheckable="True" IsChecked="True"/>
            <MenuItem x:Name="MenuStartup" Header="开机自动出现" IsCheckable="True"/>
            <Separator/>
            <MenuItem x:Name="MenuExit" Header="让小灵离开"/>
        </ContextMenu>
    </Window.ContextMenu>
    <Border Background="Transparent" Padding="10,8,12,10">
        <Border.LayoutTransform>
            <ScaleTransform x:Name="RootScale" ScaleX="0.72" ScaleY="0.72"/>
        </Border.LayoutTransform>
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="164"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border x:Name="Card" Grid.Column="1" CornerRadius="22" Padding="18,14,14,14" Margin="6,20,0,0" MinWidth="292">
            <Border.Background>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#F0161C2B" Offset="0"/>
                    <GradientStop Color="#F01C2638" Offset="1"/>
                </LinearGradientBrush>
            </Border.Background>
            <Border.BorderBrush>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#66FFFFFF" Offset="0"/>
                    <GradientStop Color="#2290F0FF" Offset="1"/>
                </LinearGradientBrush>
            </Border.BorderBrush>
            <Border.BorderThickness>1</Border.BorderThickness>
            <Border.Effect>
                <DropShadowEffect BlurRadius="28" ShadowDepth="0" Opacity="0.55" Color="#000000"/>
            </Border.Effect>
            <StackPanel>
                <Grid>
                    <StackPanel>
                        <TextBlock Text="小灵" Foreground="White" FontSize="20" FontWeight="Bold"/>
                        <TextBlock x:Name="MachineText" Text="正在认识这台电脑…" Foreground="#9FB0C8" FontSize="11" Margin="0,2,28,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <Button x:Name="CloseBtn" Content="×" Width="26" Height="26" HorizontalAlignment="Right" VerticalAlignment="Top"
                            Foreground="#D5DEEA" FontSize="16" Cursor="Hand" Background="Transparent" BorderThickness="0">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="bd" Background="Transparent" CornerRadius="13">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                                <ControlTemplate.Triggers>
                                    <Trigger Property="IsMouseOver" Value="True">
                                        <Setter TargetName="bd" Property="Background" Value="#33FFFFFF"/>
                                    </Trigger>
                                </ControlTemplate.Triggers>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </Grid>
                <TextBlock x:Name="MoodText" Text="刚醒过来" Foreground="#B7F3FF" FontSize="13" Margin="0,8,0,2"/>
                <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="CPU" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="CpuBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#67E8F9"/>
                    </Border>
                    <TextBlock x:Name="CpuVal" Grid.Column="2" Text="--" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="内存" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="RamBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#A78BFA"/>
                    </Border>
                    <TextBlock x:Name="RamVal" Grid.Column="2" Text="--" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <Grid x:Name="DiskRow" Margin="0,8,0,0" Background="Transparent" Cursor="Hand">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="磁盘" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="DiskBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#FBBF24"/>
                    </Border>
                    <TextBlock x:Name="DiskVal" Grid.Column="2" Text="--" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <StackPanel x:Name="DiskHost" Margin="46,4,0,0" Visibility="Collapsed"/>
                <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="温度" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="TempBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#FB7185"/>
                    </Border>
                    <TextBlock x:Name="TempVal" Grid.Column="2" Text="--" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="TempHint" Text="热区读取中" Foreground="#8EA0B8" FontSize="11" Margin="46,3,0,0"/>
                <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="显卡" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="GpuBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#34D399"/>
                    </Border>
                    <TextBlock x:Name="GpuVal" Grid.Column="2" Text="读取中" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="GpuHint" Text="" Foreground="#8EA0B8" FontSize="11" Margin="46,3,0,0" TextWrapping="Wrap"/>
                <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="网速" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="NetBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#38BDF8"/>
                    </Border>
                    <TextBlock x:Name="NetVal" Grid.Column="2" Text="--" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="NetHint" Text="↓ --    ↑ --" Foreground="#8EA0B8" FontSize="11" Margin="46,3,0,0" HorizontalAlignment="Right"/>
                <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="Wi-Fi" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <TextBlock x:Name="IpVal" Grid.Column="1" Grid.ColumnSpan="2" Text="读取中" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <StackPanel x:Name="VpnHost" Margin="0,8,0,0" Visibility="Collapsed"/>
                <Grid x:Name="BatteryRow" Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="108"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="电池" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" Height="8" CornerRadius="4" Background="#22FFFFFF" Margin="0,0,8,0">
                        <Border x:Name="BatBar" Width="0" Height="8" HorizontalAlignment="Left" CornerRadius="4" Background="#4ADE80"/>
                    </Border>
                    <TextBlock x:Name="BatVal" Grid.Column="2" Text="--" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <Grid Margin="0,12,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="46"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="48"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="大小" Foreground="#D5DEEA" VerticalAlignment="Center"/>
                    <Slider x:Name="SizeSlider" Grid.Column="1" Minimum="10" Maximum="140" Value="72" SmallChange="2" LargeChange="10" VerticalAlignment="Center" Margin="0,0,8,0" Cursor="SizeWE">
                        <Slider.Template>
                            <ControlTemplate TargetType="Slider">
                                <Grid Height="18" VerticalAlignment="Center">
                                    <Border Height="4" CornerRadius="2" Background="#22FFFFFF" VerticalAlignment="Center"/>
                                    <Track x:Name="PART_Track">
                                        <Track.DecreaseRepeatButton>
                                            <RepeatButton Command="Slider.DecreaseLarge" Opacity="0"/>
                                        </Track.DecreaseRepeatButton>
                                        <Track.IncreaseRepeatButton>
                                            <RepeatButton Command="Slider.IncreaseLarge" Opacity="0"/>
                                        </Track.IncreaseRepeatButton>
                                        <Track.Thumb>
                                            <Thumb Width="14" Height="14">
                                                <Thumb.Template>
                                                    <ControlTemplate TargetType="Thumb">
                                                        <Ellipse Fill="#67E8F9"/>
                                                    </ControlTemplate>
                                                </Thumb.Template>
                                            </Thumb>
                                        </Track.Thumb>
                                    </Track>
                                </Grid>
                            </ControlTemplate>
                        </Slider.Template>
                    </Slider>
                    <TextBlock x:Name="SizeVal" Grid.Column="2" Text="72%" Foreground="White" HorizontalAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="FootText" Text="拖动换位置，滚轮或滑条可缩放" Foreground="#7E90A8" FontSize="11" Margin="0,8,0,0"/>
            </StackPanel>
        </Border>

        <Canvas x:Name="Pet" Grid.Column="0" Width="164" Height="210" HorizontalAlignment="Center" VerticalAlignment="Center" Panel.ZIndex="2">
            <Canvas.RenderTransform>
                <TranslateTransform x:Name="PetBob" Y="0"/>
            </Canvas.RenderTransform>
            <Ellipse Canvas.Left="36" Canvas.Top="168" Width="96" Height="16" Fill="#33000000"/>
            <Ellipse x:Name="Aura" Canvas.Left="16" Canvas.Top="42" Width="132" Height="132" Opacity="0.55">
                <Ellipse.Fill>
                    <RadialGradientBrush>
                        <GradientStop x:Name="AuraC1" Color="#8867E8F9" Offset="0"/>
                        <GradientStop x:Name="AuraC2" Color="#0067E8F9" Offset="1"/>
                    </RadialGradientBrush>
                </Ellipse.Fill>
            </Ellipse>
            <Ellipse x:Name="Tail" Canvas.Left="112" Canvas.Top="118" Width="40" Height="24" RenderTransformOrigin="0,0.5">
                <Ellipse.RenderTransform>
                    <RotateTransform x:Name="TailRotate" Angle="18"/>
                </Ellipse.RenderTransform>
                <Ellipse.Fill>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop x:Name="TailC1" Color="#8B7CFF" Offset="0"/>
                        <GradientStop x:Name="TailC2" Color="#5CE1FF" Offset="1"/>
                    </LinearGradientBrush>
                </Ellipse.Fill>
            </Ellipse>
            <Polygon x:Name="EarL" Points="46,78 28,34 74,64" Fill="#7C6CFF"/>
            <Polygon x:Name="EarR" Points="122,78 140,34 94,64" Fill="#5AD4FF"/>
            <Polygon Points="48,74 36,44 68,66" Fill="#F7C6E4"/>
            <Polygon Points="120,74 132,44 100,66" Fill="#F7C6E4"/>
            <Ellipse Canvas.Left="28" Canvas.Top="62" Width="112" Height="112">
                <Ellipse.Fill>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop x:Name="BodyC1" Color="#6D5EF5" Offset="0"/>
                        <GradientStop x:Name="BodyC2" Color="#49D6FF" Offset="1"/>
                    </LinearGradientBrush>
                </Ellipse.Fill>
                <Ellipse.Effect>
                    <DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35" Color="#1B2437"/>
                </Ellipse.Effect>
            </Ellipse>
            <Ellipse Canvas.Left="48" Canvas.Top="98" Width="72" Height="54" Fill="#33FFFFFF"/>
            <Ellipse x:Name="EyeL" Canvas.Left="52" Canvas.Top="96" Width="24" Height="28" Fill="White"/>
            <Ellipse x:Name="EyeR" Canvas.Left="92" Canvas.Top="96" Width="24" Height="28" Fill="White"/>
            <Ellipse x:Name="PupilL" Canvas.Left="60" Canvas.Top="106" Width="11" Height="13" Fill="#1B2433"/>
            <Ellipse x:Name="PupilR" Canvas.Left="100" Canvas.Top="106" Width="11" Height="13" Fill="#1B2433"/>
            <Ellipse Canvas.Left="62" Canvas.Top="108" Width="4" Height="4" Fill="White"/>
            <Ellipse Canvas.Left="102" Canvas.Top="108" Width="4" Height="4" Fill="White"/>
            <Ellipse x:Name="LidL" Canvas.Left="52" Canvas.Top="96" Width="24" Height="28" Fill="#6D5EF5" Opacity="0"/>
            <Ellipse x:Name="LidR" Canvas.Left="92" Canvas.Top="96" Width="24" Height="28" Fill="#6D5EF5" Opacity="0"/>
            <Path x:Name="Mouth" Stroke="#3A2E6A" StrokeThickness="2.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Fill="Transparent"
                  Data="M 72,132 Q 84,144 96,132"/>
            <Ellipse Canvas.Left="40" Canvas.Top="126" Width="16" Height="10" Fill="#66FF8FB8"/>
            <Ellipse Canvas.Left="112" Canvas.Top="126" Width="16" Height="10" Fill="#66FF8FB8"/>
            <Ellipse x:Name="Crystal" Canvas.Left="74" Canvas.Top="22" Width="20" Height="20">
                <Ellipse.Fill>
                    <RadialGradientBrush>
                        <GradientStop Color="#FFFFFFFF" Offset="0"/>
                        <GradientStop x:Name="CrystalC" Color="#7AF0FF" Offset="1"/>
                    </RadialGradientBrush>
                </Ellipse.Fill>
            </Ellipse>
            <TextBlock x:Name="Zzz" Canvas.Left="118" Canvas.Top="36" Text="" Foreground="#E0F2FE" FontSize="16" FontWeight="Bold" Opacity="0"/>
        </Canvas>
    </Grid>
    </Border>
</Window>
'@

$reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader $xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

function Find($name) { return $window.FindName($name) }

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
    $bar.Width = 118 * ($clamped / 100.0)
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

function Set-Expanded {
    param([bool]$Show)
    $script:expanded = $Show
    if ($Show) {
        $card.Visibility = 'Visible'
        (Find 'MenuPanel').Header = '收起数据'
        (Find 'FootText').Text = '拖动换位置，滚轮或滑条可缩放'
    } else {
        $card.Visibility = 'Collapsed'
        (Find 'MenuPanel').Header = '展开数据'
    }
}

$settings = @{ Left = $null; Top = $null; Topmost = $true; Expanded = $true; Scale = 0.72 }
if (Test-Path $statePath) {
    try {
        $saved = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $settings.Left = $saved.Left
        $settings.Top = $saved.Top
        if ($null -ne $saved.Topmost) { $settings.Topmost = [bool]$saved.Topmost }
        if ($null -ne $saved.Expanded) { $settings.Expanded = [bool]$saved.Expanded }
        if ($null -ne $saved.Scale) { $settings.Scale = [double]$saved.Scale }
    } catch {}
}

$window.Topmost = [bool]$settings.Topmost
(Find 'MenuTopmost').IsChecked = $window.Topmost
Set-Expanded ([bool]$settings.Expanded)

$script:scale = 0.72
$script:scaleLock = $false
function Set-PetScale {
    param([double]$Value)
    $Value = [math]::Round($Value, 2)
    if ($Value -lt 0.1) { $Value = 0.1 }
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
    $payload = @{
        Left     = [math]::Round($window.Left, 1)
        Top      = [math]::Round($window.Top, 1)
        Topmost  = [bool]$window.Topmost
        Expanded = [bool]$script:expanded
        Scale    = $script:scale
    }
    ($payload | ConvertTo-Json) | Set-Content -Path $statePath -Encoding UTF8
}

function Move-ToCorner {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
    $hwnd = $helper.EnsureHandle()
    $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd)
    $area = $screen.WorkingArea
    $dpi = [SpiritNative.Dpi]::GetDpiForWindow($hwnd)
    if ($dpi -lt 96) { $dpi = 96 }
    $scale = $dpi / 96.0
    $window.UpdateLayout()
    $window.Left = ($area.Right / $scale) - $window.ActualWidth - 28
    $window.Top = ($area.Bottom / $scale) - $window.ActualHeight - 24
}

function Test-OnScreen {
    $helper = New-Object System.Windows.Interop.WindowInteropHelper $window
    $hwnd = $helper.Handle
    if ($hwnd -eq [IntPtr]::Zero) { return $true }
    $dpi = [SpiritNative.Dpi]::GetDpiForWindow($hwnd)
    if ($dpi -lt 96) { $dpi = 96 }
    $scale = $dpi / 96.0
    $x = [int]($window.Left * $scale + 40)
    $y = [int]($window.Top * $scale + 40)
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($screen.WorkingArea.Contains($x, $y)) { return $true }
    }
    return $false
}

$pointer = @{ Down = $false; Dragged = $false; X = 0; Y = 0 }
$anim = @{ Tick = 0; Blink = 0; NextBlink = 90; Mood = '' }
$diskStamp = ''
$script:vpnStamp = ''

function New-StarPoints {
    param([double]$CenterX, [double]$CenterY, [double]$Outer, [double]$Inner)
    $points = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt 10; $i++) {
        $angle = (-90 + ($i * 36)) * [math]::PI / 180
        $radius = $Outer
        if ($i % 2 -eq 1) { $radius = $Inner }
        $x = $CenterX + ($radius * [math]::Cos($angle))
        $y = $CenterY + ($radius * [math]::Sin($angle))
        $points.Add((New-Object System.Windows.Point $x, $y))
    }
    return ,$points
}

function Add-FlagStar {
    param($Canvas, [double]$CenterX, [double]$CenterY, [double]$Outer, [double]$Inner, [string]$Color = '#FFDE00')
    $star = New-Object System.Windows.Shapes.Polygon
    $star.Points = New-StarPoints $CenterX $CenterY $Outer $Inner
    $star.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    [void]$Canvas.Children.Add($star)
}

function Add-FlagRect {
    param($Canvas, [double]$X, [double]$Y, [double]$Width, [double]$Height, [string]$Color)
    $rect = New-Object System.Windows.Shapes.Rectangle
    $rect.Width = $Width
    $rect.Height = $Height
    $rect.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    [System.Windows.Controls.Canvas]::SetLeft($rect, $X)
    [System.Windows.Controls.Canvas]::SetTop($rect, $Y)
    [void]$Canvas.Children.Add($rect)
}

function Add-FlagEllipse {
    param($Canvas, [double]$CenterX, [double]$CenterY, [double]$Width, [double]$Height, [string]$Color, [double]$Angle)
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = $Width
    $dot.Height = $Height
    $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $dot.RenderTransformOrigin = '0.5,0.5'
    $turn = New-Object System.Windows.Media.RotateTransform
    $turn.Angle = $Angle
    $dot.RenderTransform = $turn
    [System.Windows.Controls.Canvas]::SetLeft($dot, ($CenterX - ($Width / 2)))
    [System.Windows.Controls.Canvas]::SetTop($dot, ($CenterY - ($Height / 2)))
    [void]$Canvas.Children.Add($dot)
}

function Set-FlagSize {
    param($HostBox, $Canvas)
    $HostBox.Width = 22
    $HostBox.Height = 15
    $HostBox.Background = [System.Windows.Media.Brushes]::Transparent
    $Canvas.Width = 22
    $Canvas.Height = 15
}

function Draw-OfficeIcon {
    param($Canvas)
    $Canvas.Children.Clear()
    $Canvas.Width = 22
    $Canvas.Height = 15
    $body = New-Object System.Windows.Shapes.Rectangle
    $body.Width = 16
    $body.Height = 12
    $body.RadiusX = 1
    $body.RadiusY = 1
    $body.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#7DD3FC')
    [System.Windows.Controls.Canvas]::SetLeft($body, 3)
    [System.Windows.Controls.Canvas]::SetTop($body, 2)
    [void]$Canvas.Children.Add($body)
    $spots = @(
        @(5, 4), @(10, 4), @(5, 8), @(10, 8)
    )
    foreach ($spot in $spots) {
        $win = New-Object System.Windows.Shapes.Rectangle
        $win.Width = 3
        $win.Height = 2
        $win.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#0F172A')
        [System.Windows.Controls.Canvas]::SetLeft($win, $spot[0])
        [System.Windows.Controls.Canvas]::SetTop($win, $spot[1])
        [void]$Canvas.Children.Add($win)
    }
}

function Draw-PlaceIcon {
    param($Canvas, [string]$Code, [string]$Kind)
    $Canvas.Children.Clear()
    $Canvas.Width = 22
    $Canvas.Height = 15
    if ($Kind -eq 'office') {
        Draw-OfficeIcon $Canvas
        return
    }
    if ($Code -eq 'HK') {
        Add-FlagRect $Canvas 0 0 22 15 '#DE2910'
        for ($i = 0; $i -lt 5; $i++) {
            $angle = -90 + ($i * 72)
            $rad = $angle * [math]::PI / 180
            $px = 11 + (2.3 * [math]::Cos($rad))
            $py = 7.5 + (2.3 * [math]::Sin($rad))
            Add-FlagEllipse $Canvas $px $py 4.2 1.7 '#FFFFFF' $angle
        }
        Add-FlagEllipse $Canvas 11 7.5 1.6 1.6 '#DE2910' 0
    } elseif ($Code -eq 'MO') {
        Add-FlagRect $Canvas 0 0 22 15 '#067662'
        for ($i = 0; $i -lt 5; $i++) {
            $angle = -90 + ($i * 72)
            $rad = $angle * [math]::PI / 180
            $px = 11 + (1.8 * [math]::Cos($rad))
            $py = 6.2 + (1.6 * [math]::Sin($rad))
            Add-FlagEllipse $Canvas $px $py 3.4 1.5 '#FFFFFF' $angle
        }
        Add-FlagRect $Canvas 4 11.2 14 1.3 '#F7D117'
    } elseif ($Code -eq 'TW') {
        Add-FlagRect $Canvas 0 0 22 15 '#FE0000'
        Add-FlagRect $Canvas 0 0 12 8 '#000095'
        Add-FlagEllipse $Canvas 6 4 5.2 5.2 '#FFFFFF' 0
        Add-FlagStar $Canvas 6 4 2.5 0.9 '#FFFFFF'
    } elseif ($Code -eq 'CN') {
        Add-FlagRect $Canvas 0 0 22 15 '#DE2910'
        Add-FlagStar $Canvas 4.6 3.8 2.2 0.85
        Add-FlagStar $Canvas 9.2 1.7 0.85 0.34
        Add-FlagStar $Canvas 11.0 3.4 0.85 0.34
        Add-FlagStar $Canvas 11.0 5.8 0.85 0.34
        Add-FlagStar $Canvas 9.2 7.5 0.85 0.34
    }
}

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
        } else {
            Set-Expanded (-not $script:expanded)
            Save-State
        }
    }
    $pointer.Down = $false
})

(Find 'CloseBtn').Add_Click({ $window.Close() })
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
(Find 'MenuStartup').Add_Click({
    $want = [bool](Find 'MenuStartup').IsChecked
    if ($want) {
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($startupLink)
        $link.TargetPath = (Get-Command powershell.exe).Source
        $link.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'pet.ps1')
        $link.WorkingDirectory = $root
        $link.WindowStyle = 7
        $link.Description = '桌面小灵宠'
        $link.Save()
    } elseif (Test-Path $startupLink) {
        Remove-Item $startupLink -Force
    }
})
(Find 'MenuStartup').IsChecked = Test-Path $startupLink

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(33)
$timer.Add_Tick({
    $anim.Tick++
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

    if (($anim.Tick % 15) -ne 0) { return }
    if (-not $sync.Ready) { return }

    $cpu = [double]$sync.Cpu
    $ramPct = [double]$sync.RamPct
    $temp = $sync.TempC
    $mood = 'calm'
    if ($null -ne $temp -and [double]$temp -ge 80) { $mood = 'hot' }
    elseif ($cpu -ge 55 -or $ramPct -ge 85) { $mood = 'busy' }
    elseif ($cpu -lt 8 -and ($null -eq $temp -or [double]$temp -lt 70)) { $mood = 'sleep' }
    if ($anim.Mood -ne $mood) {
        $anim.Mood = $mood
        Set-Mood $mood
    }

    $moodLabel = '在桌面上发呆'
    if ($mood -eq 'hot') { $moodLabel = '有点热，我想吹吹风' }
    elseif ($mood -eq 'busy') { $moodLabel = '这台电脑正在忙' }
    elseif ($mood -eq 'sleep') { $moodLabel = '好安静，我打个盹' }
    (Find 'MoodText').Text = $moodLabel
    (Find 'MachineText').Text = '{0} · {1}' -f $sync.CpuName, $sync.UptimeText

    $cpuText = '{0:N0}%' -f $cpu
    if ($sync.CpuMhz) { $cpuText = '{0:N0}% · {1:N1} GHz' -f $cpu, ([double]$sync.CpuMhz / 1000) }
    (Find 'CpuVal').Text = $cpuText
    Set-Bar 'CpuBar' $cpu

    (Find 'RamVal').Text = '{0:N1}/{1:N1} GB' -f [double]$sync.RamUsedGB, [double]$sync.RamTotalGB
    Set-Bar 'RamBar' $ramPct

    $diskPct = 0.0
    if ($null -ne $sync.DiskUsedPct) { $diskPct = [double]$sync.DiskUsedPct }
    $diskMark = '›'
    if ($script:diskOpen) { $diskMark = '⌄' }
    (Find 'DiskVal').Text = ('{0:N0}% {1}' -f $diskPct, $diskMark)
    Set-Bar 'DiskBar' $diskPct
    if ($script:diskOpen) {
        $rows = @($sync.Disks)
        $stamp = (($rows | ForEach-Object { '{0}{1}' -f $_.Name, $_.UsedPct }) -join '|')
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
        $zone = [string]$sync.TempZone
        if (-not $zone) { $zone = 'THM0' }
        $hint = '固件热区 {0}' -f $zone
        if ($null -ne $sync.Passive -and [double]$sync.Passive -lt 99) {
            $hint = '{0} · 正在温控降频' -f $hint
        }
        (Find 'TempHint').Text = $hint
    }

    if ($sync.GpuKnown -and $null -ne $sync.Gpu) {
        (Find 'GpuVal').Text = '{0:N0}%' -f [double]$sync.Gpu
        Set-Bar 'GpuBar' ([double]$sync.Gpu)
    }
    (Find 'GpuHint').Text = [string]$sync.GpuName

    $downText = Format-Rate ([double]$sync.NetDown)
    $upText = Format-Rate ([double]$sync.NetUp)
    $netBytes = [double]$sync.NetDown + [double]$sync.NetUp
    $netPct = 0.0
    if ($netBytes -ge 1KB) { $netPct = [math]::Min(100, ($netBytes / 8MB) * 100) }
    (Find 'NetVal').Text = ('↓ {0}' -f $downText)
    $netHint = '↑ {0}' -f $upText
    if ($sync.NetName) { $netHint = '{0}   {1}' -f $sync.NetName, $netHint }
    (Find 'NetHint').Text = $netHint
    Set-Bar 'NetBar' $netPct
    if ($sync.IpAddress) { (Find 'IpVal').Text = [string]$sync.IpAddress }
    else { (Find 'IpVal').Text = '未连接' }
    $vpnRows = @($sync.VpnRows)
    $vpnStamp = (($vpnRows | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Label, $_.Ip, $_.Place, $_.Code }) -join ';')
    if ($vpnStamp -ne $script:vpnStamp) {
        $script:vpnStamp = $vpnStamp
        $vpnHost = Find 'VpnHost'
        $vpnHost.Children.Clear()
        if (-not $sync.VpnOn -or $vpnRows.Count -eq 0) {
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

    if ($sync.HasBattery) {
        (Find 'BatteryRow').Visibility = 'Visible'
        $pct = [double]$sync.BatteryPct
        Set-Bar 'BatBar' $pct
        if ($sync.Charging) { $batText = '充电 {0:N0}%' -f $pct }
        elseif (-not $sync.OnAc) { $batText = '放电 {0:N0}%' -f $pct }
        else { $batText = '电源 {0:N0}%' -f $pct }
        (Find 'BatVal').Text = $batText
    } else {
        (Find 'BatteryRow').Visibility = 'Collapsed'
    }

    if ($Shot -and -not $script:ShotDone -and $null -ne $temp) {
        $script:ShotDone = $true
        $window.UpdateLayout()
        $width = [int][math]::Ceiling($window.ActualWidth)
        $height = [int][math]::Ceiling($window.ActualHeight)
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $width, $height, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($window)
        $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $shotPath = Join-Path $root 'preview.png'
        $stream = [System.IO.File]::Open($shotPath, 'Create')
        $encoder.Save($stream)
        $stream.Close()
    }
})
$timer.Start()

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = '桌面小灵宠'
$notify.Visible = $true
$notify.Add_DoubleClick({
    Move-ToCorner
    Set-Expanded $true
    $window.Activate()
    Save-State
})

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
    Save-State
    $sync.Stop = $true
    try { $notify.Visible = $false; $notify.Dispose() } catch {}
    try { $fast.Stop() } catch {}
    try { $gpuPs.Stop() } catch {}
    try { $fastRs.Close() } catch {}
    try { $gpuRs.Close() } catch {}
    try { $created.ReleaseMutex() } catch {}
    try { $created.Dispose() } catch {}
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

try {
    $null = $window.ShowDialog()
} catch {
    Write-PetLog $_.Exception.ToString()
    throw
}
