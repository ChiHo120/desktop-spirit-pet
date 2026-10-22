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
