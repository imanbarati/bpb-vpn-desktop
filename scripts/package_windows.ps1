$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $repoRoot "build\windows\x64\runner\Release"
$distRoot = Join-Path $repoRoot "dist"
$stageRoot = Join-Path $distRoot "BPB-VPN-Windows-x64"
$zipPath = Join-Path $distRoot "BPB-VPN-Windows-x64.zip"

if (-not (Test-Path (Join-Path $buildRoot "bpb.exe"))) {
    throw "Flutter Windows executable is missing: $buildRoot\bpb.exe"
}
if (-not (Test-Path (Join-Path $buildRoot "data\xray.exe"))) {
    throw "Xray executable is missing. Run build_xray_windows.ps1 before packaging."
}

New-Item -ItemType Directory -Force -Path $distRoot | Out-Null
if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
Copy-Item (Join-Path $buildRoot "*") $stageRoot -Recurse -Force
Copy-Item (Join-Path $repoRoot "README.md") $stageRoot -Force
Copy-Item (Join-Path $repoRoot "LICENSE") $stageRoot -Force
New-Item -ItemType Directory -Force -Path (Join-Path $stageRoot "docs") | Out-Null
Copy-Item (Join-Path $repoRoot "windows\README.md") (Join-Path $stageRoot "docs\Windows-preview.md") -Force
Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -CompressionLevel Optimal
Write-Host "Created portable Windows preview: $zipPath"
