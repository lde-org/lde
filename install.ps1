$ErrorActionPreference = "Stop"

$repo    = "codebycruz/lpm"
$dir     = "$env:USERPROFILE\.lpm"
$bin     = Join-Path $dir "lpm.exe"
$nightly = $args -contains "--nightly"
$versionIndex = [array]::IndexOf($args, "--version")
$version = if ($versionIndex -ge 0) { $args[$versionIndex + 1] } else { $null }

Write-Host "args: $args"
Write-Host "nightly: $nightly"
Write-Host "version: $version"

if ($nightly) {
    $tag = "nightly"
} elseif ($version) {
    $tag = "v$version"
} else {
    $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
}

$arch = if ($env:RUNNER_ARCH -eq "ARM64") { "aarch64" } else { "x86-64" }

New-Item -ItemType Directory $dir -Force | Out-Null
Write-Host "Downloading: https://github.com/$repo/releases/download/$tag/lpm-windows-$arch.exe"
Invoke-WebRequest "https://github.com/$repo/releases/download/$tag/lpm-windows-$arch.exe" -OutFile $bin

& $bin --setup
