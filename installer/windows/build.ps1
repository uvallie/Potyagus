# Збирає Windows-шелл Потягуся і пакує інсталятор dist\windows\Potyagus-<версія>-Setup.exe.
# Потрібні .NET SDK і Inno Setup 6.3+ (winget install JRSoftware.InnoSetup).
#   .\installer\windows\build.ps1 -Version 0.4
param(
  [string]$Version = '0.0.0',
  [string]$Project = $env:WINDOWS_PROJECT
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$dist = Join-Path $root 'dist\windows'
$publish = Join-Path $dist 'publish'

if (-not $Project) {
  $Project = Get-ChildItem (Join-Path $root 'windows') -Recurse -Filter *.csproj -ErrorAction SilentlyContinue |
    Where-Object Name -notmatch 'Test' | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Project) { throw 'Windows shell project not found: expected windows\**\*.csproj (or set WINDOWS_PROJECT).' }
Write-Host "→ project: $Project"

Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
# dotnet хоче числову версію; для dev-збірок лишається 0.0.0.
$numeric = if ($Version -match '^\d+(\.\d+){0,3}$') { $Version } else { '0.0.0' }
dotnet publish $Project -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -p:Version=$numeric -o $publish
if ($LASTEXITCODE) { throw "dotnet publish failed ($LASTEXITCODE)" }
Get-ChildItem $publish -Filter *.pdb | Remove-Item

$exe = Get-ChildItem $publish -Filter *.exe | Where-Object Name -ne 'createdump.exe' |
  Sort-Object { $_.Name -ne 'Potyagus.exe' } | Select-Object -First 1
if (-not $exe) { throw "no .exe in $publish" }
Write-Host "→ app: $($exe.Name)"
& (Join-Path $PSScriptRoot 'sign.ps1') $exe.FullName

$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $iscc) {
  $iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found' }

& $iscc "/DAppVersion=$Version" "/DSourceDir=$publish" "/DAppExe=$($exe.Name)" "/DOutputDir=$dist" (Join-Path $PSScriptRoot 'potyagus.iss')
if ($LASTEXITCODE) { throw "ISCC failed ($LASTEXITCODE)" }

$setup = Join-Path $dist "Potyagus-$Version-Setup.exe"
& (Join-Path $PSScriptRoot 'sign.ps1') $setup
Write-Host "✓ $setup ($([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB)"
