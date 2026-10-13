# 读取本机性能计数器、电池和 IP。国家只记录代码和名称，不下载文件。

function Convert-ToCelsius {
    param([double]$Raw)
    if ($Raw -le 0) { return $null }
    if ($Raw -gt 1000) { $Raw = $Raw / 10.0 }
    if ($Raw -gt 200) { return [math]::Round($Raw - 273.15, 1) }
    return [math]::Round($Raw, 1)
}

function Format-UptimeText {
    param([TimeSpan]$Span)
    if ($Span.TotalDays -ge 1) {
        return ('已开机 {0}天{1}小时' -f [int]$Span.TotalDays, $Span.Hours)
    }
    if ($Span.TotalHours -ge 1) {
        return ('已开机 {0}小时{1}分' -f [int]$Span.TotalHours, $Span.Minutes)
    }
    return ('已开机 {0}分钟' -f [math]::Max(1, [int]$Span.TotalMinutes))
}

function Get-CounterMap {
    param([string[]]$Paths)
    $map = @{}
    try {
        $set = Get-Counter -Counter $Paths -ErrorAction Stop
        foreach ($sample in $set.CounterSamples) {
            $map[$sample.Path.ToLowerInvariant()] = $sample
        }
    } catch {
    }
    return $map
}

function Initialize-SpiritSensors {
    if ($script:SpiritReady) { return }
    $script:Boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $script:NetTracks = @()
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
        $net = Get-Counter '\Network Interface(*)\Bytes Received/sec' -ErrorAction Stop
        $tracks = @()
        foreach ($sample in $net.CounterSamples) {
            $name = [string]$sample.InstanceName
            if ($name -match 'isatap|teredo|loopback|pseudo|vethernet|wsl|bluetooth|vpn|miniport') { continue }
            $down = $sample.Path
            $up = $down -replace 'bytes received/sec$', 'bytes sent/sec'
            $tracks += @{ Name = $name; Down = $down; Up = $up }
        }
        $script:NetTracks = $tracks
    } catch {
        $script:NetTracks = @()
    }
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cs = Get-CimInstance Win32_ComputerSystem
        $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
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
        if ($nic.OperationalStatus.ToString() -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType.ToString() -eq 'Loopback') { continue }
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
    }
    return $bestIp
}

function Get-WifiVpn {
    $result = @{ Wifi = ''; Vpn = ''; VpnOn = $false; VpnName = ''; VpnIps = @() }
    $vpnIps = New-Object System.Collections.Generic.List[string]
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
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
    $now = Get-Date
    if ($script:Geo -and $script:GeoAt -and $script:GeoLocal -eq $LocalIp -and (($now - $script:GeoAt).TotalMinutes -lt 15)) {
        return $script:Geo
    }
    $geo = @{ Code = ''; Name = ''; PublicIp = '' }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $info = $null
        try {
            $raw = Invoke-RestMethod -Uri 'http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,query' -TimeoutSec 5
            if ($raw.status -eq 'success' -and $raw.countryCode) {
                $info = [pscustomobject]@{
                    country_code = [string]$raw.countryCode
                    country      = [string]$raw.country
                    region       = [string]$raw.regionName
                    city         = [string]$raw.city
                    public_ip    = [string]$raw.query
                }
            }
        } catch {}
        if (-not $info) {
            $raw = Invoke-RestMethod -Uri 'https://ipwho.is/' -TimeoutSec 5
            if ($raw.success -and $raw.country_code) {
                $info = $raw
                $info | Add-Member -NotePropertyName public_ip -NotePropertyValue ([string]$raw.ip) -Force
            }
        }
        if ($info -and $info.country_code) {
            $place = Resolve-Place $info
            $geo.Code = $place.Code
            $geo.Name = $place.English
            $geo.PublicIp = [string]$info.public_ip
        }
    } catch {
        if ($script:Geo) { return $script:Geo }
    }
    $script:Geo = $geo
    $script:GeoAt = $now
    $script:GeoLocal = $LocalIp
    return $geo
}

function Get-SpiritSnapshot {
    Initialize-SpiritSensors
    $snap = @{
        MachineLine = $script:MachineLine
        CpuName     = $script:CpuName
        GpuName     = $script:GpuName
        UptimeText  = Format-UptimeText ((Get-Date) - $script:Boot)
        Cpu         = 0.0
        CpuMhz      = $null
        RamPct      = 0.0
        RamUsedGB   = 0.0
        RamTotalGB  = 0.0
        DiskBusy    = 0.0
        DiskRead    = 0.0
        DiskWrite   = 0.0
        Disks       = @()
        DiskUsedPct = 0
        DiskUsedGB  = 0.0
        DiskTotalGB = 0.0
        TempC       = $null
        TempZone    = ''
        Passive     = $null
        NetDown     = 0.0
        NetUp       = 0.0
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
    $freq = Get-CounterMap @('\Processor Information(_Total)\Processor Frequency')
    foreach ($key in $freq.Keys) {
        $snap.CpuMhz = [math]::Round([double]$freq[$key].CookedValue, 0)
    }
    $thermal = Get-CounterMap @(
        '\Thermal Zone Information(*)\High Precision Temperature',
        '\Thermal Zone Information(*)\Temperature',
        '\Thermal Zone Information(*)\% Passive Limit'
    )
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
    $netPaths = @()
    foreach ($track in $script:NetTracks) {
        $netPaths += $track.Down
        $netPaths += $track.Up
    }
    $bestName = ''
    if ($netPaths.Count -gt 0) {
        $netMap = Get-CounterMap $netPaths
        $downSum = 0.0
        $upSum = 0.0
        $best = 0.0
        foreach ($track in $script:NetTracks) {
            $down = 0.0
            $up = 0.0
            $dk = $track.Down.ToLowerInvariant()
            $uk = $track.Up.ToLowerInvariant()
            if ($netMap.ContainsKey($dk)) { $down = [math]::Max(0, [double]$netMap[$dk].CookedValue) }
            if ($netMap.ContainsKey($uk)) { $up = [math]::Max(0, [double]$netMap[$uk].CookedValue) }
            $downSum += $down
            $upSum += $up
            if (($down + $up) -gt $best) {
                $best = $down + $up
                $bestName = [string]$track.Name
            }
        }
        $snap.NetDown = $downSum
        $snap.NetUp = $upSum
        if ($bestName -match 'wi-?fi|wlan|wireless') { $snap.NetName = 'Wi-Fi' }
        elseif ($bestName -match 'ethernet') { $snap.NetName = '以太网' }
        elseif ($bestName) { $snap.NetName = '网络' }
    }
    $links = Get-WifiVpn
    $snap.IpAddress = [string]$links.Wifi
    $snap.VpnName = [string]$links.VpnName
    $vpnRows = @()
    if ($links.VpnOn) {
        $geo = Update-IpCountry ([string]$links.Vpn)
        $snap.CountryCode = [string]$geo.Code
        $snap.CountryName = [string]$geo.Name
        $publicIp = [string]$geo.PublicIp
        $tunnelIps = @($links.VpnIps)
        $publicIsPrivate = $publicIp -match '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'
        if ($publicIp -and -not $publicIsPrivate -and ($tunnelIps -notcontains $publicIp)) {
            $vpnRows += @{ Label = '上网'; Kind = 'flag'; Ip = $publicIp; Code = [string]$geo.Code; Place = [string]$geo.Name }
        }
        foreach ($tunnelIp in $tunnelIps) {
            $vpnRows += @{ Label = '内网'; Kind = 'office'; Ip = [string]$tunnelIp; Code = ''; Place = '企业内网' }
        }
        if ($vpnRows.Count -eq 0 -and $links.Vpn) {
            $vpnRows += @{ Label = 'VPN'; Kind = 'flag'; Ip = [string]$links.Vpn; Code = [string]$geo.Code; Place = [string]$geo.Name }
        }
    }
    $snap.VpnRows = $vpnRows
    $snap.VpnOn = ($vpnRows.Count -gt 0)
    $snap.VpnAddress = if ($vpnRows.Count -gt 0) { [string]$vpnRows[0].Ip } else { '' }
    $diskRows = @()
    $diskTotal = 0.0
    $diskUsed = 0.0
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
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
    }
    $snap.Disks = $diskRows
    $snap.DiskUsedGB = [math]::Round($diskUsed / 1GB, 1)
    $snap.DiskTotalGB = [math]::Round($diskTotal / 1GB, 1)
    if ($diskTotal -gt 0) { $snap.DiskUsedPct = [int][math]::Round(($diskUsed / $diskTotal) * 100, 0) }
    if ($script:HasForms) {
        $power = [System.Windows.Forms.SystemInformation]::PowerStatus
        $flags = $power.BatteryChargeStatus
        $none = [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery
        $charging = [System.Windows.Forms.BatteryChargeStatus]::Charging
        if (-not ($flags -band $none) -and $power.BatteryLifePercent -ge 0) {
            $snap.HasBattery = $true
            $snap.BatteryPct = [int][math]::Round($power.BatteryLifePercent * 100, 0)
            $snap.Charging = [bool]($flags -band $charging)
            $snap.OnAc = ($power.PowerLineStatus.ToString() -eq 'Online')
        }
    }
    return $snap
}

function Get-GpuBusyPercent {
    $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
    $sums = @{}
    foreach ($sample in $samples) {
        $name = [string]$sample.InstanceName
        $kind = ''
        if ($name -match 'engtype_3d') { $kind = '3d' }
        elseif ($name -match 'engtype_compute|engtype_VideoProcessing|engtype_videodecode') { $kind = 'media' }
        else { continue }
        $id = 'gpu'
        if ($name -match 'luid_0x[0-9a-f]+_0x([0-9a-f]+)') { $id = $Matches[1] }
        $key = $id + '|' + $kind
        if (-not $sums.ContainsKey($key)) { $sums[$key] = 0.0 }
        $sums[$key] += [double]$sample.CookedValue
    }
    $best = 0.0
    foreach ($key in $sums.Keys) {
        if ($key -notlike '*|3d') { continue }
        $value = [math]::Min(100, [math]::Max(0, $sums[$key]))
        if ($value -gt $best) { $best = $value }
    }
    if ($best -lt 1) {
        foreach ($key in $sums.Keys) {
            $value = [math]::Min(100, [math]::Max(0, $sums[$key]))
            if ($value -gt $best) { $best = $value }
        }
    }
    return [math]::Round($best, 0)
}
