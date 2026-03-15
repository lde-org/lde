$ErrorActionPreference = "Stop"

$repo = "codebycruz/lpm"
$dir  = "$env:USERPROFILE\.lpm"
$bin  = Join-Path $dir "lpm.exe"
$tag  = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name

New-Item -ItemType Directory $dir -Force | Out-Null
Invoke-WebRequest "https://github.com/$repo/releases/download/$tag/lpm-windows-x86-64.exe" -OutFile $bin

& $bin --setup
