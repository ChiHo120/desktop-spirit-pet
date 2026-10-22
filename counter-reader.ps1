# Persistent category samples: no Get-Counter sampling delay and no English-only paths.
$script:CounterHistory = @{}
$script:CounterRetryAt = @{}
$script:CounterErrors = @{}
$script:CounterNames = $null
$script:CounterCache = @{}

function Get-LocalCounterName {
    param([string]$Name)
    if ($null -eq $script:CounterNames) {
        $script:CounterNames = @{}
        try {
            $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib'
            $english = (Get-ItemProperty -LiteralPath ($base + '\009') -Name Counter -ErrorAction Stop).Counter
            $local = (Get-ItemProperty -LiteralPath ($base + '\CurrentLanguage') -Name Counter -ErrorAction Stop).Counter
            $byId = @{}
            for ($i = 0; $i -lt $local.Length - 1; $i += 2) { $byId[$local[$i]] = $local[$i + 1] }
            for ($i = 0; $i -lt $english.Length - 1; $i += 2) {
                if ($byId.ContainsKey($english[$i])) { $script:CounterNames[$english[$i + 1]] = $byId[$english[$i]] }
            }
        } catch { $script:CounterNames = @{} }
    }
    if ($script:CounterNames.ContainsKey($Name)) { return $script:CounterNames[$Name] }
    return $Name
}

function Get-CounterMap {
    param([string[]]$Paths, [int]$CacheSeconds = 0)
    $cacheKey = $Paths -join "|"
    $cached = $script:CounterCache[$cacheKey]
    if ($CacheSeconds -gt 0 -and $cached -and ([datetime]::UtcNow - $cached.At).TotalSeconds -lt $CacheSeconds) { return $cached.Map }
    $map = @{}
    $groups = @{}
    foreach ($counterPath in $Paths) {
        if ($counterPath -notmatch '^\\([^\(]+)\((.*)\)\\(.+)$') { continue }
        $category = $Matches[1]
        if (-not $groups.ContainsKey($category)) { $groups[$category] = @() }
        $groups[$category] += @{ Instance = $Matches[2]; Counter = $Matches[3] }
    }
    foreach ($category in $groups.Keys) {
        $now = [datetime]::UtcNow
        if ($script:CounterRetryAt[$category] -and $now -lt $script:CounterRetryAt[$category]) { continue }
        try {
            $reader = New-Object System.Diagnostics.PerformanceCounterCategory (Get-LocalCounterName $category)
            $current = $reader.ReadCategory()
            $previous = $script:CounterHistory[$category]
            foreach ($request in $groups[$category]) {
                $counterName = Get-LocalCounterName $request.Counter
                if (-not $current.Contains($counterName)) { continue }
                $instances = $current[$counterName]
                foreach ($instance in $instances.Keys) {
                    if ($request.Instance -ne '*' -and $instance -ne $request.Instance) { continue }
                    $sample = $instances[$instance].Sample
                    $old = $null
                    if ($previous -and $previous.Contains($counterName) -and $previous[$counterName].Contains($instance)) {
                        $old = $previous[$counterName][$instance].Sample
                    }
                    if ($null -ne $old) {
                        $value = [double][System.Diagnostics.CounterSample]::Calculate($old, $sample)
                    } elseif ($sample.CounterType.ToString() -match '^NumberOfItems|^RawFraction$') {
                        $value = [double][System.Diagnostics.CounterSample]::Calculate($sample)
                    } else { continue } # Rate counters need two genuine sample points.
                    if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { continue }
                    $key = ('\{0}({1})\{2}' -f $category, $instance, $request.Counter).ToLowerInvariant()
                    $map[$key] = [pscustomobject]@{ Path = $key; InstanceName = $instance; CookedValue = $value }
                }
            }
            $script:CounterHistory[$category] = $current
            $script:CounterErrors.Remove($category)
            $script:CounterRetryAt.Remove($category)
        } catch {
            $script:CounterErrors[$category] = $_.Exception.Message
            $script:CounterHistory.Remove($category)
            $script:CounterRetryAt[$category] = $now.AddSeconds(30)
        }
    }
    if ($CacheSeconds -gt 0) { $script:CounterCache[$cacheKey] = @{ At = [datetime]::UtcNow; Map = $map } }
    return $map
}
