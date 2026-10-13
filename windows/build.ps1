# Build Potyagus for Windows → windows\dist\Potyagus\ (Potyagus.exe + web\ + exercises.json)
# Needs the .NET 8 SDK: winget install Microsoft.DotNet.SDK.8
param(
    [string]$Runtime = "win-x64"   # or win-arm64
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here "dist\Potyagus"

if (Test-Path $out) { Remove-Item -Recurse -Force $out }

Write-Host "→ збираю ($Runtime)…"
dotnet publish (Join-Path $here "Potyagus.Windows.csproj") `
    -c Release -r $Runtime --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    -p:DebugType=none `
    -o $out
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$zip = Join-Path $here "dist\Potyagus-windows-$Runtime.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $out -DestinationPath $zip

Write-Host "✓ зібрано: $out\Potyagus.exe"
Write-Host "✓ архів:   $zip"
