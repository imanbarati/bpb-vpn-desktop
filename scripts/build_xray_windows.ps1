$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$xrayDir = Join-Path $repoRoot "xray"
$outDir = Join-Path $repoRoot "build\windows\x64\runner\Release\data"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Push-Location $xrayDir
try {
    go version
    $env:CGO_ENABLED = "0"
    go build -trimpath -buildvcs=false -ldflags "-s -w" -o (Join-Path $outDir "xray.exe") ./cmd/bpb-xray
}
finally {
    Pop-Location
}

$geoDir = Join-Path $repoRoot "android\app\src\main\assets"
foreach ($name in @("geoip.dat", "geosite.dat")) {
    $source = Join-Path $geoDir $name
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $outDir $name) -Force
    }
}
Write-Host "Windows Xray binary staged in $outDir"
