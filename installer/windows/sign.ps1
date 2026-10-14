# Підписує файл, якщо в середовищі є сертифікат (WINDOWS_CERT_PFX_BASE64 + WINDOWS_CERT_PASSWORD).
# Без сертифіката нічого не робить: збірка лишається непідписаною, і Windows показує SmartScreen.
param([Parameter(Mandatory)][string]$File)
$ErrorActionPreference = 'Stop'

if (-not $env:WINDOWS_CERT_PFX_BASE64) {
  Write-Host "unsigned: $File"
  exit 0
}

$pfx = Join-Path ([IO.Path]::GetTempPath()) 'potyagus-sign.pfx'
[IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CERT_PFX_BASE64))
try {
  $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
    Where-Object FullName -match '\\x64\\' | Sort-Object FullName -Descending | Select-Object -First 1
  if (-not $signtool) { throw 'signtool.exe not found (Windows SDK)' }
  & $signtool.FullName sign /f $pfx /p $env:WINDOWS_CERT_PASSWORD /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $File
  if ($LASTEXITCODE) { throw "signtool failed ($LASTEXITCODE)" }
} finally {
  Remove-Item $pfx -Force -ErrorAction SilentlyContinue
}
