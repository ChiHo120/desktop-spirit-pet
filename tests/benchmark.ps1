param([ValidateRange(3,30)][int]$Samples = 5)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'sensors.ps1')
$durations=@()
for($i=0;$i -lt $Samples;$i++) {
    $watch=[diagnostics.stopwatch]::StartNew()
    $snapshot=Get-SpiritSnapshot
    $watch.Stop()
    if($i -gt 0){$durations += $watch.Elapsed.TotalMilliseconds}
    # Do not print machine names, addresses or location data.
    Write-Output ('Sample {0}: {1:N1} ms; CPU available={2}; RAM available={3}; network available={4}; provider errors={5}' -f $i,$watch.Elapsed.TotalMilliseconds,($null -ne $snapshot.Cpu),($null -ne $snapshot.RamPct),($null -ne $snapshot.NetDown),$snapshot.SensorErrors.Count)
    Start-Sleep -Seconds 1
}
Write-Output ('Warm snapshot average: {0:N1} ms' -f ($durations | Measure-Object -Average).Average)
