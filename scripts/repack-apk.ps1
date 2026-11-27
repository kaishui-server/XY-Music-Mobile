# APK delivery slimming: re-compress the unsigned APK at max deflate level,
# drop unused entries, then zipalign + re-sign.
# Why: Gradle packs with default deflate; flutter_inappwebview's t_rex_runner
# offline game assets (~30KB) cannot be excluded via packaging.excludes
# (AGP 9 removed packaging.assets). Max-level deflate on .so saves 100KB+,
# meeting the 20MiB hard limit.
# Usage: powershell -File scripts\repack-apk.ps1 -Apk <unsigned.apk> -Out <out.apk>
param(
    [Parameter(Mandatory = $true)][string]$Apk,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Entries dropped from the final APK (never read at runtime). packaging
# excludes in build.gradle.kts only cover Java resources; flutter asset
# entries must be dropped here.
$excludePatterns = @(
    "assets/flutter_assets/packages/flutter_inappwebview/assets/t_rex_runner/"
)

# resources.arsc must be STORED (uncompressed) for targetSdk 30+.
$storedEntries = @("resources.arsc")

$src = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $Apk).Path)
$dstStream = [System.IO.File]::Open($Out, [System.IO.FileMode]::Create)
$dst = New-Object System.IO.Compression.ZipArchive($dstStream, [System.IO.Compression.ZipArchiveMode]::Create)

try {
    foreach ($entry in $src.Entries) {
        $skip = $false
        foreach ($pat in $excludePatterns) {
            if ($entry.FullName.StartsWith($pat)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $level = [System.IO.Compression.CompressionLevel]::Optimal
        if ($storedEntries -contains $entry.FullName) {
            $level = [System.IO.Compression.CompressionLevel]::NoCompression
        }
        $new = $dst.CreateEntry($entry.FullName, $level)
        # Note: do NOT use $in/$out — $in collides with the case-insensitive
        # automatic variable $INPUT in PowerShell.
        $entryStream = $entry.Open()
        $newStream = $new.Open()
        $buf = New-Object byte[] 65536
        while (($n = $entryStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $newStream.Write($buf, 0, $n)
        }
        $newStream.Dispose(); $entryStream.Dispose()
        # Preserve external attributes (Unix permission bits for lib/*.so).
        $new.ExternalAttributes = $entry.ExternalAttributes
    }
}
finally {
    $dst.Dispose(); $dstStream.Dispose(); $src.Dispose()
}

$before = (Get-Item $Apk).Length
$after = (Get-Item $Out).Length
"repack: {0:N0} -> {1:N0} bytes (saved {2:N0})" -f $before, $after, ($before - $after)
