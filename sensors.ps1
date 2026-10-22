# 读取本机性能计数器、电池和 IP。国家只记录代码和名称，不下载文件。

function Convert-ToCelsius {
    param([double]$Raw)
    if ([double]::IsNaN($Raw) -or [double]::IsInfinity($Raw) -or $Raw -le 0) { return $null }
    if ($Raw -gt 1000) { $Raw = $Raw / 10.0 }
    if ($Raw -gt 200) { $Raw -= 273.15 }
    if ($Raw -lt -40 -or $Raw -gt 150) { return $null }
    return [math]::Round($Raw, 1)
}

function Format-UptimeText {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1) {
        return ('已开机 {0}天{1}小时' -f $Span.Days, $Span.Hours)
    }
    if ($Span.TotalHours -ge 1) {
        return ('已开机 {0}小时{1}分' -f [math]::Floor($Span.TotalHours), $Span.Minutes)
    }
    return ('已开机 {0}分钟' -f [math]::Max(1, [math]::Floor($Span.TotalMinutes)))
}

. (Join-Path $PSScriptRoot 'counter-reader.ps1')

function Initialize-SpiritSensors {
    if ($script:SpiritReady) { return }
    try { $script:Boot = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3 -ErrorAction Stop).LastBootUpTime }
    catch { $script:Boot = $null }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $script:HasForms = $true
    } catch {
        $script:HasForms = $false
    }
    if (-not ('SpiritNative.Memory' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace SpiritNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct MemoryStatus {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
    public static class Memory {
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GlobalMemoryStatusEx(ref MemoryStatus lpBuffer);
    }
}
"@
    }
    try {
        $cpu = Get-CimInstance Win32_Processor -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object -First 1
        $cs = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 3 -ErrorAction Stop
        $gpu = Get-CimInstance Win32_VideoController -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object -First 1
        $script:MachineLine = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        $script:CpuName = ($cpu.Name -replace '\(R\)|\(TM\)', '' -replace '\s+', ' ').Trim()
        $script:GpuName = ($gpu.Name -replace '\(R\)|\(TM\)', '' -replace '\s+', ' ').Trim()
    } catch {
        $script:MachineLine = $env:COMPUTERNAME
        $script:CpuName = 'CPU'
        $script:GpuName = 'GPU'
    }
    $script:SpiritReady = $true
}

function Get-NormalizedNicName {
    param([string]$Name)
    if (-not $Name) { return '' }
    return (($Name.ToLowerInvariant() -replace '\(r\)|\(tm\)|\[r\]|\[tm\]', '') -replace '[^a-z0-9]', '')
}

function Get-PreferredIPv4 {
    param([string]$AdapterHint)
    $hint = Get-NormalizedNicName $AdapterHint
    $bestIp = ''
    $bestScore = -1
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
        if ($nic.OperationalStatus.ToString() -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType.ToString() -eq 'Loopback') { continue }
        if (($nic.Name + ' ' + $nic.Description) -match 'vmware|virtualbox|hyper-v|vethernet|bluetooth|wsl|wintun|wireguard|tap-windows|tailscale|zerotier') { continue }
        $addr = ''
        $props = $nic.GetIPProperties()
        foreach ($uni in $props.UnicastAddresses) {
            if ($uni.Address.AddressFamily.ToString() -ne 'InterNetwork') { continue }
            $text = $uni.Address.ToString()
            if ($text -like '169.254.*' -or $text -eq '0.0.0.0') { continue }
            $addr = $text
            break
        }
        if (-not $addr) { continue }
        $score = 0
        $desc = Get-NormalizedNicName $nic.Description
        $adapterName = Get-NormalizedNicName $nic.Name
        if ($hint -and ($desc -eq $hint -or $adapterName -eq $hint -or ($desc -and $hint.Contains($desc)) -or ($desc -and $desc.Contains($hint)))) { $score += 10 }
        foreach ($gw in $props.GatewayAddresses) {
            if ($gw.Address -and $gw.Address.ToString() -ne '0.0.0.0') { $score += 3; break }
        }
        if ($desc -match 'wifi|wlan|wireless' -or $adapterName -match 'wifi|wlan') { $score += 1 }
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestIp = $addr
        }
        } catch { continue }
    }
    return $bestIp
}

function Get-WifiVpn {
    $result = @{ Wifi = ''; Vpn = ''; VpnOn = $false; VpnName = ''; VpnIps = @() }
    $vpnIps = New-Object System.Collections.Generic.List[string]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
        if ($nic.OperationalStatus.ToString() -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType.ToString() -eq 'Loopback') { continue }
        $name = [string]$nic.Name
        $desc = [string]$nic.Description
        $blob = ($name + ' ' + $desc).ToLowerInvariant()
        if ($blob -match 'vmware|virtualbox|hyper-v|vethernet|bluetooth|loopback|wsl|isatap|teredo') { continue }
        $addr = ''
        foreach ($uni in $nic.GetIPProperties().UnicastAddresses) {
            if ($uni.Address.AddressFamily.ToString() -ne 'InterNetwork') { continue }
            $text = $uni.Address.ToString()
            if ($text -like '169.254.*' -or $text -eq '0.0.0.0') { continue }
            $addr = $text
            break
        }
        if (-not $addr) { continue }
        $isVpn = $blob -match 'wintun|tap-windows|wireguard|openvpn|anyconnect|corplink|corp link|clash|nordlynx|tailscale|zerotier|forticlient|globalprotect|pulse secure'
        $isWifi = (-not $isVpn) -and ($nic.NetworkInterfaceType.ToString() -eq 'Wireless80211' -or $blob -match 'wlan|wi-?fi|wireless')
        if ($isWifi) {
            if (-not $result.Wifi -or $name -notmatch '\d') { $result.Wifi = $addr }
        }
        if ($isVpn) {
            $result.VpnOn = $true
            if (-not $result.Vpn) { $result.Vpn = $addr }
            if (-not $result.VpnName) { $result.VpnName = $name }
            if (-not $vpnIps.Contains($addr)) { [void]$vpnIps.Add($addr) }
        }
        } catch { continue }
    }
    $result.VpnIps = @($vpnIps)
    return $result
}

function Format-PlaceLabel {
    param([string]$English, [string]$City)
    $cityName = ([string]$City).Trim()
    if (-not $cityName) { return $English }
    if ($cityName.Equals($English, [System.StringComparison]::OrdinalIgnoreCase)) { return $English }
    return ('{0} · {1}' -f $English, $cityName)
}

function Resolve-Place {
    param($Info)
    $code = ([string]$Info.country_code).ToUpperInvariant()
    $city = [string]$Info.city
    $area = (([string]$Info.region) + ' ' + $city + ' ' + ([string]$Info.country)).ToLowerInvariant()
    if ($code -eq 'HK' -or $area -match 'hong kong|hongkong|香港') {
        return @{ Code = 'HK'; English = (Format-PlaceLabel 'Hong Kong' $city) }
    }
    if ($code -eq 'MO' -or $area -match 'macau|macao|澳門|澳门') {
        return @{ Code = 'MO'; English = (Format-PlaceLabel 'Macau' $city) }
    }
    if ($code -eq 'TW' -or $area -match 'taiwan|台灣|台湾') {
        return @{ Code = 'TW'; English = (Format-PlaceLabel 'Taiwan' $city) }
    }
    if ($code -eq 'CN') {
        return @{ Code = 'CN'; English = (Format-PlaceLabel 'China' $city) }
    }
    $english = [string]$Info.country
    if (-not $english) { $english = $code }
    return @{ Code = $code; English = (Format-PlaceLabel $english $city) }
}

function Update-IpCountry {
    param([string]$LocalIp)
    $now = [datetime]::UtcNow
    if ($script:GeoLocal -ne $LocalIp) {
        $script:Geo = $null
        $script:GeoNext = $null
        $script:GeoLocal = $LocalIp
    }
    if ($script:GeoNext -and $now -lt $script:GeoNext) { return $script:Geo }
    # Failures are cached too; never attach a previous network's location to a new one.
    $script:GeoNext = $now.AddSeconds(60)
    $script:Geo = @{ Code = ''; Name = ''; PublicIp = '' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $info = Invoke-RestMethod -Uri 'https://ipwho.is/' -TimeoutSec 5 -ErrorAction Stop
        if (-not $info.success -or -not $info.country_code) { return $script:Geo }
        $place = Resolve-Place $info
        $script:Geo = @{ Code = $place.Code; Name = $place.English; PublicIp = [string]$info.ip }
        $script:GeoNext = $now.AddMinutes(15)
    } catch { } # Optional service: background worker retries after the backoff.
    return $script:Geo
}

function Get-GpuAggregate {
    param($Samples)
    $engines = @{}
    foreach ($sample in $Samples) {
        $name = [string]$sample.InstanceName
        if ($name -notmatch '(luid_0x[0-9a-f]+_0x[0-9a-f]+_phys_\d+_eng_\d+)') { continue }
        $key = $Matches[1]
        if (-not $engines.ContainsKey($key)) { $engines[$key] = 0.0 }
        $engines[$key] += [math]::Max(0, [double]$sample.CookedValue)
    }
    if ($engines.Count -eq 0) { return $null }
    # Sum processes on the same physical engine, then select the busiest engine.
    $best = ($engines.Values | Measure-Object -Maximum).Maximum
    return [math]::Round([math]::Min(100, $best), 0)
}

function Get-SpiritSnapshot {
    param($GeoResult)
    Initialize-SpiritSensors
    $snap = @{
        MachineLine = $script:MachineLine
        CpuName     = $script:CpuName
        GpuName     = $script:GpuName
        UptimeText  = if ($script:Boot) { Format-UptimeText ((Get-Date) - $script:Boot) } else { '开机时间未知' }
        Cpu         = $null
        CpuMhz      = $null
        RamPct      = $null
        RamUsedGB   = 0.0
        RamTotalGB  = 0.0
        DiskBusy    = $null
        DiskRead    = $null
        DiskWrite   = $null
        Disks       = @()
        DiskUsedPct = $null
        DiskUsedGB  = 0.0
        DiskTotalGB = 0.0
        PrimaryDisk = ''
        PrimaryDiskFreeGB = $null
        DiskAlert = $false
        TempC       = $null
        TempZone    = ''
        Passive     = $null
        NetDown     = $null
        NetUp       = $null
        NetName     = ''
        IpAddress   = ''
        VpnOn       = $false
        VpnRows     = @()
        VpnName     = ''
        CountryCode = ''
        CountryName = ''
        HasBattery  = $false
        BatteryPct  = $null
        OnAc        = $true
        Charging    = $false
        Error       = ''
    }
    $mem = New-Object SpiritNative.MemoryStatus
    $mem.dwLength = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'SpiritNative.MemoryStatus')
    if ([SpiritNative.Memory]::GlobalMemoryStatusEx([ref]$mem)) {
        $snap.RamTotalGB = [math]::Round($mem.ullTotalPhys / 1GB, 1)
        $used = [double]$mem.ullTotalPhys - [double]$mem.ullAvailPhys
        if ($used -lt 0) { $used = 0 }
        $snap.RamUsedGB = [math]::Round($used / 1GB, 1)
        if ($mem.ullTotalPhys -gt 0) {
            $snap.RamPct = [math]::Round(($used / $mem.ullTotalPhys) * 100, 1)
        }
    }
    $basic = Get-CounterMap @(
        '\Processor(_Total)\% Processor Time',
        '\PhysicalDisk(_Total)\% Disk Time',
        '\PhysicalDisk(_Total)\Disk Read Bytes/sec',
        '\PhysicalDisk(_Total)\Disk Write Bytes/sec'
    )
    foreach ($key in $basic.Keys) {
        $value = [double]$basic[$key].CookedValue
        if ($key -like '*\% processor time') { $snap.Cpu = [math]::Round([math]::Min(100, [math]::Max(0, $value)), 1) }
        elseif ($key -like '*% disk time') { $snap.DiskBusy = [math]::Round([math]::Min(100, [math]::Max(0, $value)), 1) }
        elseif ($key -like '*disk read bytes/sec') { $snap.DiskRead = [math]::Max(0, $value) }
        elseif ($key -like '*disk write bytes/sec') { $snap.DiskWrite = [math]::Max(0, $value) }
    }
    $freq = Get-CounterMap @('\Processor Information(_Total)\Processor Frequency') -CacheSeconds 5
    foreach ($key in $freq.Keys) {
        $snap.CpuMhz = [math]::Round([double]$freq[$key].CookedValue, 0)
    }
    $thermal = Get-CounterMap @(
        '\Thermal Zone Information(*)\High Precision Temperature',
        '\Thermal Zone Information(*)\Temperature',
        '\Thermal Zone Information(*)\% Passive Limit'
    ) -CacheSeconds 5
    $bestHp = $null
    $bestPlain = $null
    $bestPassive = $null
    foreach ($key in $thermal.Keys) {
        $sample = $thermal[$key]
        if ($key -like '*high precision temperature*') {
            $celsius = Convert-ToCelsius ([double]$sample.CookedValue)
            if ($null -ne $celsius -and ($null -eq $bestHp -or $celsius -gt $bestHp.C)) {
                $bestHp = @{ C = $celsius; Zone = [string]$sample.InstanceName }
            }
        } elseif ($key -like '*\temperature') {
            $celsius = Convert-ToCelsius ([double]$sample.CookedValue)
            if ($null -ne $celsius -and ($null -eq $bestPlain -or $celsius -gt $bestPlain.C)) {
                $bestPlain = @{ C = $celsius; Zone = [string]$sample.InstanceName }
            }
        } elseif ($key -like '*passive limit*') {
            $limit = [double]$sample.CookedValue
            if ($null -eq $bestPassive -or $limit -lt $bestPassive) { $bestPassive = $limit }
        }
    }
    $chosen = $bestHp
    if ($null -eq $chosen) { $chosen = $bestPlain }
    if ($null -ne $chosen) {
        $snap.TempC = $chosen.C
        $snap.TempZone = ($chosen.Zone -replace '^\\_tz\.', '' -replace '\\', '').ToUpperInvariant()
    }
    $snap.Passive = $bestPassive
    $netMap = Get-CounterMap @('\Network Interface(*)\Bytes Received/sec', '\Network Interface(*)\Bytes Sent/sec')
    $bestName = ''
    $best = -1.0
    foreach ($sample in $netMap.Values) {
        if ($sample.InstanceName -match 'isatap|teredo|loopback|pseudo|vethernet|wsl|bluetooth|vpn|miniport|wintun|wireguard|tap-windows|tailscale|zerotier') { continue }
        $value = [math]::Max(0, [double]$sample.CookedValue)
        if ($null -eq $snap.NetDown) { $snap.NetDown = 0.0; $snap.NetUp = 0.0 }
        if ($sample.Path -like '*bytes received/sec') { $snap.NetDown += $value }
        else { $snap.NetUp += $value }
        if ($value -gt $best) { $best = $value; $bestName = $sample.InstanceName }
    }
    if ($bestName -match 'wi-?fi|wlan|wireless') { $snap.NetName = 'Wi-Fi' }
    elseif ($bestName) { $snap.NetName = '网络' }
    $links = Get-WifiVpn
    $snap.IpAddress = [string]$links.Wifi
    $snap.IpLabel = 'Wi-Fi'
    if (-not $snap.IpAddress) { $snap.IpAddress = Get-PreferredIPv4 $bestName; $snap.IpLabel = '本机 IP' }
    $snap.GeoKey = if ($links.VpnOn) { ([string]$links.VpnName) + '|' + ((@($links.VpnIps) | Sort-Object) -join ',') + '|' + $snap.IpAddress } else { '' }
    $snap.VpnName = [string]$links.VpnName
    $vpnRows = @()
    if ($links.VpnOn) {
        $geo = @{ Code = ''; Name = ''; PublicIp = '' }
        if ($GeoResult -and $GeoResult.Key -eq $snap.GeoKey) { $geo = $GeoResult.Data }
        $snap.CountryCode = [string]$geo.Code
        $snap.CountryName = [string]$geo.Name
        $publicIp = [string]$geo.PublicIp
        $tunnelIps = @($links.VpnIps)
        $publicIsPrivate = $publicIp -match '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'
        if ($publicIp -and -not $publicIsPrivate -and ($tunnelIps -notcontains $publicIp)) {
            $vpnRows += @{ Label = '上网'; Kind = 'flag'; Ip = $publicIp; Code = [string]$geo.Code; Place = [string]$geo.Name }
        }
        foreach ($tunnelIp in $tunnelIps) {
            $vpnRows += @{ Label = '内网'; Kind = 'office'; Ip = [string]$tunnelIp; Code = ''; Place = '隧道地址' }
        }
        if ($vpnRows.Count -eq 0 -and $links.Vpn) {
            $vpnRows += @{ Label = 'VPN'; Kind = 'flag'; Ip = [string]$links.Vpn; Code = [string]$geo.Code; Place = [string]$geo.Name }
        }
    }
    $snap.VpnRows = $vpnRows
    $snap.VpnOn = ($vpnRows.Count -gt 0)
    $snap.VpnAddress = if ($vpnRows.Count -gt 0) { [string]$vpnRows[0].Ip } else { '' }
    if (-not $script:DiskAt -or ([datetime]::UtcNow - $script:DiskAt).TotalSeconds -ge 30) {
    $diskRows = @()
    $diskTotal = 0.0
    $diskUsed = 0.0
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
        if (-not $drive.IsReady) { continue }
        if ($drive.DriveType.ToString() -ne 'Fixed') { continue }
        $size = [double]$drive.TotalSize
        $free = [double]$drive.AvailableFreeSpace
        $usedBytes = $size - $free
        if ($usedBytes -lt 0) { $usedBytes = 0 }
        $pct = 0
        if ($size -gt 0) { $pct = [int][math]::Round(($usedBytes / $size) * 100, 0) }
        $diskTotal += $size
        $diskUsed += $usedBytes
        $diskRows += @{
            Name    = $drive.Name.TrimEnd('\')
            UsedPct = $pct
            FreeGB  = [math]::Round($free / 1GB, 1)
            SizeGB  = [math]::Round($size / 1GB, 1)
        }
        } catch { $snap.Error = '部分磁盘暂不可用' }
    }
    $snap.Disks = $diskRows
    $systemDisk = $diskRows | Where-Object { $_.Name -eq $env:SystemDrive } | Select-Object -First 1
    $tightestDisk = $diskRows | Sort-Object FreeGB | Select-Object -First 1
    $urgentDisk = $diskRows | Where-Object { $_.FreeGB -lt 10 -or $_.UsedPct -ge 90 } | Sort-Object FreeGB | Select-Object -First 1
    $focusDisk = if ($urgentDisk) { $urgentDisk } elseif ($systemDisk) { $systemDisk } else { $tightestDisk }
    if ($focusDisk) {
        $snap.PrimaryDisk = [string]$focusDisk.Name
        $snap.PrimaryDiskFreeGB = [double]$focusDisk.FreeGB
        $snap.DiskAlert = ([double]$focusDisk.FreeGB -lt 10 -or [double]$focusDisk.UsedPct -ge 90)
    }
    $snap.DiskUsedGB = [math]::Round($diskUsed / 1GB, 1)
    $snap.DiskTotalGB = [math]::Round($diskTotal / 1GB, 1)
    if ($diskTotal -gt 0) { $snap.DiskUsedPct = [int][math]::Round(($diskUsed / $diskTotal) * 100, 0) }
        $script:DiskCache = @{}
        foreach ($key in @('Disks','DiskUsedGB','DiskTotalGB','DiskUsedPct','PrimaryDisk','PrimaryDiskFreeGB','DiskAlert','Error')) { $script:DiskCache[$key] = $snap[$key] }
        $script:DiskAt = [datetime]::UtcNow
    } else {
        foreach ($key in $script:DiskCache.Keys) { $snap[$key] = $script:DiskCache[$key] }
    }
    if ($script:HasForms) {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        $flags = $power.BatteryChargeStatus
        $none = [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery
        $charging = [System.Windows.Forms.BatteryChargeStatus]::Charging
        if ($flags -ne [System.Windows.Forms.BatteryChargeStatus]::Unknown -and -not ($flags -band $none) -and $power.BatteryLifePercent -ge 0 -and $power.BatteryLifePercent -le 1) {
            $snap.HasBattery = $true
            $snap.BatteryPct = [int][math]::Round($power.BatteryLifePercent * 100, 0)
            $snap.Charging = [bool]($flags -band $charging)
            $snap.OnAc = ($power.PowerLineStatus.ToString() -eq 'Online')
        }
    }
    $snap.SampledAt = [datetime]::UtcNow
    $snap.SensorErrors = @{}
    foreach ($key in $script:CounterErrors.Keys) { $snap.SensorErrors[$key] = $script:CounterErrors[$key] }
    return $snap
}

function Get-GpuBusyPercent {
    $map = Get-CounterMap @('\GPU Engine(*)\Utilization Percentage')
    if ($script:CounterErrors['GPU Engine']) { throw $script:CounterErrors['GPU Engine'] }
    return Get-GpuAggregate @($map.Values)
}
