function Write-SpiritLog {
    param([string]$Path, [string]$Message)
    try {
        if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 1MB) {
            Move-Item -LiteralPath $Path -Destination ($Path + '.1') -Force -ErrorAction Stop
        }
        Add-Content -LiteralPath $Path -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding UTF8 -ErrorAction Stop
    } catch { } # Logging must never interrupt cleanup or crash the UI.
}

function Read-SpiritState {
    param([string]$Path)
    $result = @{ Left = $null; Top = $null; Topmost = $true; Expanded = $true; Scale = 0.72; GeoEnabled = $false; ReducedMotion = $false; PrivacyMode = $false }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $result }
    try {
        $saved = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('Left','Top','Scale')) {
            $value = $saved.$key
            if ($null -eq $value) { continue }
            $number = 0.0
            if (-not [double]::TryParse([string]$value, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) { continue }
            if ($key -eq 'Scale') { $number = [math]::Max(0.45, [math]::Min(1.4, $number)) }
            elseif ([math]::Abs($number) -gt 100000) { continue }
            $result[$key] = $number
        }
        foreach ($key in @('Topmost','Expanded','GeoEnabled','ReducedMotion','PrivacyMode')) {
            if ($saved.$key -is [bool]) { $result[$key] = $saved.$key }
        }
    } catch {
        # Preserve the damaged input for diagnosis before replacing it with defaults.
        try { Copy-Item -LiteralPath $Path -Destination ($Path + '.invalid') -Force -ErrorAction Stop } catch {}
    }
    return $result
}

function Write-SpiritState {
    param([string]$Path, [hashtable]$State)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $json = $State | ConvertTo-Json -Depth 4 -ErrorAction Stop
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($true))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, ($Path + '.bak'), $true) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
