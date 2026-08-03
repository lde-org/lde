$ErrorActionPreference = "Stop"

$repo    = "lde-org/lde"
$dir     = "$env:USERPROFILE\.lde"
$bin     = Join-Path $dir "lde.exe"
$nightly = $args -contains "--nightly"
$versionIndex = [array]::IndexOf($args, "--version")
$version = if ($versionIndex -ge 0) { $args[$versionIndex + 1] } else { $null }

if ($nightly) {
    $tag = "nightly"
} elseif ($version) {
    $tag = "v$version"
} else {
    $tag = ((Invoke-WebRequest "https://github.com/$repo/releases/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue).Headers.Location -split '/')[-1]
}

$rawArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$arch = if ($rawArch -eq "Arm64") { "aarch64" } else { "x86-64" }
$exe = "lde-windows-$arch.exe"

$zip = Join-Path $dir "lde.zip"

New-Item -ItemType Directory $dir -Force | Out-Null
Invoke-WebRequest "https://github.com/$repo/releases/download/$tag/lde-windows-$arch.zip" -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $dir -Force
Move-Item -Path (Join-Path $dir $exe) -Destination $bin -Force
Remove-Item $zip -Force

& $bin --setup
