# Ставить інсталятор тихо, перевіряє, що все на місці, запускає гуся, ставить поверх і видаляє.
# Запускається в CI на чистій Windows-машині GitHub (на своєму ПК не запускай: він прибере твого Потягуся).
#   .\installer\windows\smoke-test.ps1 -Setup dist\windows\Potyagus-0.4-Setup.exe
param([Parameter(Mandatory)][string]$Setup)
$ErrorActionPreference = 'Stop'

$app = Join-Path $env:LOCALAPPDATA 'Programs\Potyagus'
$exe = Join-Path $app 'Potyagus.exe'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6BA3AE6C-7A5C-451D-B571-7653B81CC1C8}_is1'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Потягусь.lnk'
$logs = Join-Path $PSScriptRoot '..\..\dist\windows\smoke-logs'
New-Item -ItemType Directory -Force $logs | Out-Null

function Check([bool]$ok, [string]$what) {
  if (-not $ok) { throw "FAIL: $what" }
  Write-Host "ok  $what"
}

function Install([string]$log) {
  $p = Start-Process $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$logs\$log`"" -Wait -PassThru
  if ($p.ExitCode -ne 0) { Get-Content "$logs\$log" -Tail 40 -ErrorAction SilentlyContinue }
  Check ($p.ExitCode -eq 0) "setup exit code 0 ($log, got $($p.ExitCode))"
}

function Running { @(Get-Process Potyagus -ErrorAction SilentlyContinue).Count -gt 0 }

# 1. Чисте встановлення
Install 'install.log'
foreach ($f in 'Potyagus.exe', 'exercises.json', 'web\overlay.html', 'web\clips\idle.mp4', 'web\sfx\honk.m4a', 'unins000.exe') {
  Check (Test-Path (Join-Path $app $f)) "installed $f"
}
Check ((Get-ItemProperty $runKey -Name Potyagus -ErrorAction SilentlyContinue).Potyagus -eq "`"$exe`"") 'autostart value points at the installed exe'
Check ((Get-ItemProperty $uninstKey -ErrorAction SilentlyContinue).DisplayName -eq 'Потягусь') 'listed in Settings → Apps'
Check (Test-Path $shortcut) 'Start menu shortcut'

# 2. Сам застосунок з місця встановлення
$p = Start-Process $exe -ArgumentList '--check' -Wait -PassThru
Check ($p.ExitCode -eq 0) "Potyagus.exe --check exit code 0 (got $($p.ExitCode))"
Start-Process $exe | Out-Null
Start-Sleep -Seconds 10
Check (Running) 'app keeps running in the tray after 10 s'

# 3. Оновлення поверх запущеного застосунку
Install 'upgrade.log'
Check (Test-Path $exe) 'exe still present after upgrade'
Get-Process Potyagus -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process $exe | Out-Null
Start-Sleep -Seconds 5
Check (Running) 'app starts again after upgrade'

# 4. Видалення (застосунок у цей момент працює)
Start-Process (Join-Path $app 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$logs\uninstall.log`"" -Wait | Out-Null
# unins000 перезапускає себе з TEMP, тож чекаємо, поки зникне exe.
for ($i = 0; $i -lt 60 -and (Test-Path $exe); $i++) { Start-Sleep -Seconds 1 }
Check (-not (Test-Path $exe)) 'exe removed'
Check (-not (Running)) 'app stopped by uninstaller'
Check ($null -eq (Get-ItemProperty $runKey -Name Potyagus -ErrorAction SilentlyContinue)) 'autostart value removed'
Check (-not (Test-Path $uninstKey)) 'removed from Settings → Apps'
Check (-not (Test-Path $shortcut)) 'Start menu shortcut removed'
Check (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'Potyagus\WebView2'))) 'WebView2 profile removed'

Write-Host '✓ smoke test passed'
