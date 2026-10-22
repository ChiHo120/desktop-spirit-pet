# No external modules, network requests or hardware reads.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'sensors.ps1')
. (Join-Path $root 'state.ps1')
$script:passed = 0
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "$Name : expected [$Expected], got [$Actual]" }
    $script:passed++
}
function Assert-True($Actual, [string]$Name) { Assert-Equal ([bool]$Actual) $true $Name }

Assert-Equal (Format-UptimeText ([timespan]::FromMinutes(111))) '已开机 1小时51分' 'Uptime must floor hours'
Assert-Equal (Format-UptimeText ([timespan]::FromHours(43))) '已开机 1天19小时' 'Uptime must floor days'
Assert-Equal (Format-UptimeText ([timespan]::FromSeconds(119))) '已开机 1分钟' 'Uptime must floor minutes'
Assert-Equal (Convert-ToCelsius 3000) 26.9 'Decikelvin'
Assert-Equal (Convert-ToCelsius 300) 26.9 'Kelvin'
Assert-Equal (Convert-ToCelsius 55) 55 'Celsius'
Assert-True ($null -eq (Convert-ToCelsius 99999)) 'Reject unrealistic temperature'
Assert-True ($null -eq (Convert-ToCelsius ([double]::NaN))) 'Reject NaN'
Assert-True ($null -eq (Convert-ToCelsius ([double]::PositiveInfinity))) 'Reject infinity'
Assert-True ($null -eq (Convert-ToCelsius 0)) 'No zero placeholder temperature'
Assert-Equal (Format-PlaceLabel 'Hong Kong' 'hong kong') 'Hong Kong' 'Deduplicate city'
Assert-Equal (Resolve-Place ([pscustomobject]@{country_code='CN';country='China';region='Shanghai';city='Shanghai'})).English 'China · Shanghai' 'City label'
Assert-Equal (Resolve-Place ([pscustomobject]@{country_code='HK';country='';region='';city=''})).Code 'HK' 'Region code'
Assert-Equal (Resolve-Place ([pscustomobject]@{country_code='US';country='United States';region='';city='Seattle'})).English 'United States · Seattle' 'Other country'

$engine = 'luid_0x00000000_0x00001234_phys_0_eng_'
$samples = @(
    [pscustomobject]@{InstanceName=('pid_1_'+$engine+'0_engtype_3D');CookedValue=30},
    [pscustomobject]@{InstanceName=('pid_2_'+$engine+'0_engtype_3D');CookedValue=20},
    [pscustomobject]@{InstanceName=('pid_3_'+$engine+'1_engtype_3D');CookedValue=40},
    [pscustomobject]@{InstanceName=('pid_4_'+$engine+'2_engtype_VideoEncode');CookedValue=65}
)
Assert-Equal (Get-GpuAggregate $samples) 65 'GPU busiest engine, including encoder'
Assert-Equal (Get-GpuAggregate @($samples[0],$samples[1],$samples[2])) 50 'GPU sum processes, not engines'
Assert-True ($null -eq (Get-GpuAggregate @())) 'No GPU samples is unknown'
Assert-Equal (Get-GpuAggregate @([pscustomobject]@{InstanceName=('pid_1_'+$engine+'0');CookedValue=130})) 100 'GPU clamp'

# Mock HTTP: verify backoff, network changes, HTTPS and success cache.
$script:httpCalls = 0
$script:httpFails = $true
function Invoke-RestMethod {
    param($Uri,$TimeoutSec,$ErrorAction)
    if ($Uri -notlike 'https://*') { throw 'HTTP is forbidden in the lookup' }
    $script:httpCalls++
    if ($script:httpFails) { throw 'Simulated offline connection' }
    return [pscustomobject]@{success=$true;country_code='US';country='United States';region='';city='Seattle';ip='203.0.113.7'}
}
$first = Update-IpCountry 'network-A'
$second = Update-IpCountry 'network-A'
Assert-Equal $script:httpCalls 1 'Failure backoff'
Assert-Equal $second.PublicIp '' 'Failure has no fabricated IP'
$script:httpFails = $false
$ok = Update-IpCountry 'network-B'
Assert-Equal $ok.PublicIp '203.0.113.7' 'Network change refreshes lookup'
$null = Update-IpCountry 'network-B'
Assert-Equal $script:httpCalls 2 'Success cache'
$script:httpFails = $true
$changed = Update-IpCountry 'network-C'
Assert-Equal $changed.PublicIp '' 'Do not reuse another network location'
Assert-Equal $script:httpCalls 3 'Changed network retries once'

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('SpiritTests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDir)
try {
    $statePath = Join-Path $testDir 'window.json'
    $defaults = Read-SpiritState $statePath
    Assert-Equal $defaults.Scale 0.72 'Default scale'
    Assert-Equal $defaults.GeoEnabled $false 'No network by default'
    Assert-Equal $defaults.PrivacyMode $false 'Privacy mode default'
    Assert-Equal $defaults.Scale 0.72 'Default scale remains usable'
    Write-SpiritState $statePath @{Left=-1500.5;Top=100;Scale=0.85;Topmost=$false;Expanded=$true;GeoEnabled=$true}
    $saved = Read-SpiritState $statePath
    Assert-Equal $saved.Left -1500.5 'Negative monitor coordinate roundtrip'
    Assert-Equal $saved.Topmost $false 'Boolean roundtrip'
    Assert-Equal $saved.GeoEnabled $true 'Privacy preference roundtrip'
    Write-SpiritState $statePath @{Scale=100;Topmost='false';Left='NaN';Top='Infinity'}
    $saved = Read-SpiritState $statePath
    Assert-Equal $saved.Scale 1.4 'Clamp scale'
    Assert-Equal $saved.Topmost $true 'Reject string boolean'
    Assert-True ($null -eq $saved.Left) 'Reject NaN coordinate'
    Assert-True ($null -eq $saved.Top) 'Reject infinite coordinate'
    [IO.File]::WriteAllText($statePath,'{ broken')
    Assert-Equal (Read-SpiritState $statePath).Scale 0.72 'Corrupt JSON fallback'
    Assert-True (Test-Path -LiteralPath ($statePath+'.invalid')) 'Preserve invalid JSON'
    Assert-Equal @(Get-ChildItem $testDir -Filter '*.tmp').Count 0 'Atomic writes leave no temp files'
    $log = Join-Path $testDir 'log.txt'
    [IO.File]::WriteAllText($log,('x' * 1MB))
    Write-SpiritLog $log 'rotation test'
    Assert-True (Test-Path -LiteralPath ($log+'.1')) 'Rotate large log'
    Assert-True ((Get-Item -LiteralPath $log).Length -lt 1KB) 'New log stays bounded'
} finally {
    # Only remove this explicitly created temporary directory.
    $resolved = [IO.Path]::GetFullPath($testDir)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'SpiritTests-*') { throw 'Unexpected cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

foreach ($file in Get-ChildItem $root -Filter '*.ps1' -Recurse) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert-Equal $errors.Count 0 ('Parse '+$file.Name)
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM '+$file.Name)
}
[xml]$xaml = Get-Content (Join-Path $root 'ui.xaml') -Raw -Encoding UTF8
$names = @($xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') })
Assert-Equal $names.Count @($names | Select-Object -Unique).Count 'Unique XAML names'
$petSource = Get-Content (Join-Path $root 'pet.ps1') -Raw -Encoding UTF8
foreach ($m in [regex]::Matches($petSource, "Find '([^']+)'")) {
    Assert-True ($names -contains $m.Groups[1].Value) ('UI reference '+$m.Groups[1].Value)
}
Write-Output ('PASS: {0} offline assertions' -f $script:passed)
