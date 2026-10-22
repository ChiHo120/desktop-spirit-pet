# Each worker publishes one complete result; the UI never reads a half-written snapshot.
function Start-SpiritWorker {
    param([hashtable]$Shared, [string]$Library, [ValidateSet('Fast','Gpu','Geo')][string]$Kind)
    $rs = [runspacefactory]::CreateRunspace()
    $ps = [powershell]::Create()
    try {
        $rs.Open()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($shared, $library, $kind)
            $ErrorActionPreference = 'Stop'
            . $library
            while (-not $shared.Stop) {
                $watch = [diagnostics.stopwatch]::StartNew()
                $interval = if ($kind -eq 'Fast') { 1000 } elseif ($kind -eq 'Gpu') { 3000 } else { 2000 }
                try {
                    switch ($kind) {
                        'Fast' {
                            $geo = if ($shared.GeoEnabled) { $shared.GeoResult } else { $null }
                            $snapshot = Get-SpiritSnapshot -GeoResult $geo
                            $shared.Snapshot = $snapshot
                            $shared.FastError = ''
                        }
                        'Gpu' {
                            $value = Get-GpuBusyPercent
                            $shared.GpuResult = @{ Value = $value; At = [datetime]::UtcNow; Error = '' }
                        }
                        'Geo' {
                            $snapshot = $shared.Snapshot
                            $key = if ($snapshot) { $snapshot.GeoKey } else { '' }
                            if ($shared.GeoEnabled -and $key) {
                                $data = Update-IpCountry $key
                                # A response in flight must not survive a changed network/setting.
                                if ($shared.GeoEnabled -and $shared.Snapshot.GeoKey -eq $key) {
                                    $shared.GeoResult = @{ Key = $key; Data = $data }
                                }
                            } else {
                                $shared.GeoResult = $null
                                $script:Geo = $null
                                $script:GeoNext = $null
                                $script:GeoLocal = $null
                            }
                        }
                    }
                } catch {
                    if ($kind -eq 'Fast') { $shared.FastError = $_.Exception.Message }
                    elseif ($kind -eq 'Gpu') { $shared.GpuResult = @{ Value = $null; At = [datetime]::UtcNow; Error = $_.Exception.Message } }
                    $interval = 5000
                }
                # A minimum yield also protects against providers that fail immediately.
                $remaining = [math]::Max(100, $interval - $watch.ElapsedMilliseconds)
                while (-not $shared.Stop -and $remaining -gt 0) {
                    $delay = [int][math]::Min(100, $remaining)
                    Start-Sleep -Milliseconds $delay
                    $remaining -= $delay
                }
            }
        }).AddArgument($Shared).AddArgument($Library).AddArgument($Kind)
        $handle = $ps.BeginInvoke()
        return @{ PowerShell = $ps; Runspace = $rs; Handle = $handle; Kind = $Kind }
    } catch {
        $ps.Dispose()
        $rs.Dispose()
        throw
    }
}

function Stop-SpiritWorkers {
    param($Workers, $Shared)
    $Shared.Stop = $true
    foreach ($worker in $Workers) {
        try { $worker.PowerShell.Stop() } catch {}
        try { $worker.PowerShell.EndInvoke($worker.Handle) | Out-Null } catch {}
        try { $worker.PowerShell.Dispose() } catch {}
        try { $worker.Runspace.Dispose() } catch {}
    }
}
