Add-Type -AssemblyName System.Drawing

function Get-ImageStats($path) {
    $img = [System.Drawing.Image]::FromFile($path)
    Write-Output ("=== " + (Split-Path $path -Leaf) + " : " + $img.Width + "x" + $img.Height + " " + $img.PixelFormat)
    $bmp = New-Object System.Drawing.Bitmap($img)
    $w = $bmp.Width; $h = $bmp.Height
    # 角落采样
    $corners = @{}
    foreach ($name in @("TL","TR","BL","BR")) {
        $x = if ($name -match "L") { 1 } else { $w - 2 }
        $y = if ($name -match "T") { 1 } else { $h - 2 }
        $c = $bmp.GetPixel($x, $y)
        $corners[$name] = $c
        Write-Output ("  corner $name : A=" + $c.A + " R=" + $c.R + " G=" + $c.G + " B=" + $c.B)
    }
    # 内容 bbox：非背景像素（透明 OR 非近白）
    $hasAlpha = ($corners["TL"].A -lt 250) -or ($corners["TR"].A -lt 250) -or ($corners["BL"].A -lt 250) -or ($corners["BR"].A -lt 250)
    $bgIsWhite = !$hasAlpha -and (($corners["TL"].R -gt 240) -and ($corners["TL"].G -gt 240) -and ($corners["TL"].B -gt 240))
    Write-Output ("  hasAlphaCorners=" + $hasAlpha + " bgIsWhite=" + $bgIsWhite)
    $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
    $step = [Math]::Max(1, [int]($w / 256))
    for ($y = 0; $y -lt $h; $y += $step) {
        for ($x = 0; $x -lt $w; $x += $step) {
            $c = $bmp.GetPixel($x, $y)
            $isContent = if ($hasAlpha) { $c.A -gt 16 } else { -not (($c.R -gt 235) -and ($c.G -gt 235) -and ($c.B -gt 235)) }
            if ($isContent) {
                if ($x -lt $minX) { $minX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -ge 0) {
        $cw = $maxX - $minX + 1; $ch = $maxY - $minY + 1
        Write-Output ("  content bbox: ($minX,$minY)-($maxX,$maxY)  size=" + $cw + "x" + $ch +
            "  ratios: L=" + [Math]::Round($minX / $w, 3) + " T=" + [Math]::Round($minY / $h, 3) +
            " W=" + [Math]::Round($cw / $w, 3) + " H=" + [Math]::Round($ch / $h, 3))
    } else {
        Write-Output "  content bbox: EMPTY"
    }
    $bmp.Dispose(); $img.Dispose()
}

Get-ImageStats "d:\GITHUB项目\XY-Music-Mobile\assets\icon\app_icon_bg.png"
Get-ImageStats "d:\GITHUB项目\XY-Music-Mobile\assets\icon\app_icon_foreground.png"
Get-ImageStats "d:\GITHUB项目\软件logo.jpg"
