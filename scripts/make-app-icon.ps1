# Builds a multi-size Windows icon (.ico) from a 1024 px logo PNG. The Windows build runs this to make the exe's
# embedded icon from file-swap-icon-pack/themes/sage/logo-1024.png, the default theme's logo.
# Usage: powershell -ExecutionPolicy Bypass -File scripts\make-app-icon.ps1 -Source <logo.png> -Output <app.ico>
param(
    [Parameter(Mandatory)] [string] $Source,
    [Parameter(Mandatory)] [string] $Output
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256

function Resize([System.Drawing.Bitmap] $image, [int] $size) {
    $result = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($result)
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $attributes = New-Object System.Drawing.Imaging.ImageAttributes
    $attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $g.DrawImage($image, (New-Object System.Drawing.Rectangle 0, 0, $size, $size), 0, 0, $image.Width, $image.Height, [System.Drawing.GraphicsUnit]::Pixel, $attributes)
    $g.Dispose()
    return $result
}

# Halving step by step before the last resize keeps the small sizes crisp.
function Scale([System.Drawing.Bitmap] $logo, [int] $size) {
    $current = New-Object System.Drawing.Bitmap $logo
    while ($current.Width / 2 -ge $size * 2) {
        $half = Resize $current ([int]($current.Width / 2))
        $current.Dispose()
        $current = $half
    }
    $final = Resize $current $size
    $current.Dispose()
    return $final
}

# 256 px is stored as PNG; smaller sizes as 32-bit DIBs, which every Windows icon reader accepts.
function Entry([System.Drawing.Bitmap] $bitmap) {
    $s = $bitmap.Width
    $stream = New-Object System.IO.MemoryStream
    if ($s -ge 256) {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return , $stream.ToArray()
    }
    $writer = New-Object System.IO.BinaryWriter $stream
    $maskRow = [int][Math]::Ceiling($s / 32.0) * 4
    $writer.Write([int]40); $writer.Write([int]$s); $writer.Write([int]($s * 2))
    $writer.Write([int16]1); $writer.Write([int16]32); $writer.Write([int]0)
    $writer.Write([int]($s * $s * 4 + $maskRow * $s)); $writer.Write([int]0); $writer.Write([int]0); $writer.Write([int]0); $writer.Write([int]0)
    $data = $bitmap.LockBits((New-Object System.Drawing.Rectangle 0, 0, $s, $s), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $row = New-Object byte[] ($s * 4)
    for ($y = $s - 1; $y -ge 0; $y--) {
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $s * 4)
        $writer.Write($row)
    }
    $bitmap.UnlockBits($data)
    $writer.Write((New-Object byte[] ($maskRow * $s)))
    $writer.Flush()
    return , $stream.ToArray()
}

$logo = New-Object System.Drawing.Bitmap (Resolve-Path $Source).Path
$entries = foreach ($size in $sizes) { $bitmap = Scale $logo $size; , (Entry $bitmap); $bitmap.Dispose() }
$logo.Dispose()

$file = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $file
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dimension); $w.Write([byte]$dimension); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$entries[$i].Length); $w.Write([int]$offset)
    $offset += $entries[$i].Length
}
foreach ($entry in $entries) { $w.Write([byte[]]$entry) }
$w.Flush()
New-Item -ItemType Directory -Force (Split-Path $Output) | Out-Null
[System.IO.File]::WriteAllBytes([System.IO.Path]::GetFullPath($Output), $file.ToArray())
