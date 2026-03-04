$ErrorActionPreference = "Stop"

$repo = "codebycruz/lpm"
$lpmDir = "$env:USERPROFILE\.lpm"
$artifact = "lpm-windows-x86-64.exe"

Write-Host "Installing lpm..." -ForegroundColor Green

# Get latest release
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest"
$tag = $release.tag_name
if (-not $tag) {
    Write-Error "Could not fetch latest release"
    exit 1
}

Write-Host "Latest version: $tag"

# Download and install binary
if (-not (Test-Path $lpmDir)) { New-Item -ItemType Directory -Path $lpmDir | Out-Null }
$installPath = Join-Path $lpmDir "lpm.exe"
Invoke-WebRequest -Uri "https://github.com/$repo/releases/download/$tag/$artifact" -OutFile $installPath

# Finish setup (PATH, lpx)
& $installPath --setup
