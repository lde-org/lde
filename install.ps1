$ErrorActionPreference = "Stop"

$repo    = "codebycruz/lpm"
$dir     = "$env:USERPROFILE\.lpm"
$bin     = Join-Path $dir "lpm.exe"
$nightly = $args -contains "--nightly"
$versionIndex = [array]::IndexOf($args, "--version")
$version = if ($versionIndex -ge 0) { $args[$versionIndex + 1] } else { $null }

if ($nightly) {
    $tag = "nightly"
} elseif ($version) {
    $tag = "v$version"
} else {
    $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}

$rawArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$arch = if ($rawArch -eq "Arm64") { "aarch64" } else { "x86-64" }

New-Item -ItemType Directory $dir -Force | Out-Null
Invoke-WebRequest "https://github.com/$repo/releases/download/$tag/lpm-windows-$arch.exe" -OutFile $bin

& $bin --setup
