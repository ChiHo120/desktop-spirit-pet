. (Join-Path $PSScriptRoot 'sensors.ps1')
$samples = @(
    @{ c = 'CN'; r = 'Shanghai'; city = 'Shanghai' },
    @{ c = 'CN'; r = 'Hong Kong'; city = 'Hong Kong' },
    @{ c = 'HK'; r = ''; city = '' },
    @{ c = 'MO'; r = 'Macau'; city = '' },
    @{ c = 'TW'; r = 'Taipei'; city = 'Taipei' }
)
foreach ($s in $samples) {
    $p = Resolve-Place ([pscustomobject]@{ country_code = $s.c; country = ''; region = $s.r; city = $s.city })
    Write-Output ($s.c + ' ' + $s.r + ' -> ' + $p.Code + ' ' + $p.English)
}
