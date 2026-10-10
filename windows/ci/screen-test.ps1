# End-to-end check on a real Windows desktop (the GitHub runner has one, with no monitor attached):
# show the goose with --now, start the exercise from the keyboard, wait for it to finish, and
# take screenshots along the way. Fails if the app never closes or doesn't log a "done".
param(
    [Parameter(Mandatory)] [string]$Exe,
    [Parameter(Mandatory)] [string]$Out
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Input {
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    // With the real scan code: the page checks KeyboardEvent.code, which Chromium derives from it.
    public static void Key(byte vk) {
        byte scan = (byte)MapVirtualKey(vk, 0);
        keybd_event(vk, scan, 0, UIntPtr.Zero); keybd_event(vk, scan, 2, UIntPtr.Zero);
    }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public static uint ForegroundPid() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return pid; }
    public static void Click(int x, int y) { SetCursorPos(x, y); mouse_event(2, 0, 0, 0, UIntPtr.Zero); mouse_event(4, 0, 0, 0, UIntPtr.Zero); }
}
"@

New-Item -ItemType Directory -Force $Out | Out-Null
$data = Join-Path $env:APPDATA "Potyagus"
Remove-Item -Recurse -Force $data -ErrorAction SilentlyContinue

function Shot([string]$name) {
    $b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "screenshot $name ($($b.Width)x$($b.Height))"
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host "screens: $([System.Windows.Forms.Screen]::AllScreens.Count), primary $screen"
Shot "0-desktop"

$p = Start-Process $Exe -ArgumentList "--now" -PassThru
Start-Sleep -Seconds 12
if ($p.HasExited) { throw "Potyagus exited before showing anything (code $($p.ExitCode))" }
Shot "1-idle"
$fg = [Input]::ForegroundPid()
Write-Host "foreground: pid $fg $((Get-Process -Id $fg -ErrorAction SilentlyContinue).ProcessName) (goose is pid $($p.Id))"

# Space starts the exercise only if the overlay really took keyboard focus.
[Input]::Key(0x20)
Start-Sleep -Milliseconds 1200
Shot "2-after-space"
# Then a click on the lawn, in case it didn't (a click mid-countdown is ignored by the page).
[Input]::Click($screen.X + [int]($screen.Width * 0.08), $screen.Y + [int]($screen.Height * 0.85))
Start-Sleep -Seconds 6
Shot "3-exercise"
Start-Sleep -Seconds 12
Shot "4-exercise-later"

# The longest exercise is about a minute; the page closes itself ~4 s after the timer ends.
$deadline = (Get-Date).AddSeconds(100)
while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
Shot "5-after"

Write-Host "--- history.jsonl"
$history = Join-Path $data "history.jsonl"
if (Test-Path $history) { Get-Content $history | Write-Host }
Write-Host "--- agent.log"
$log = Join-Path $data "agent.log"
if (Test-Path $log) { Get-Content $log | Write-Host }

if (-not $p.HasExited) { Stop-Process $p -Force; throw "the overlay was still up after the exercise should have ended" }
if (-not (Test-Path $history) -or -not (Select-String -Path $history -Pattern '"reason":"done"' -Quiet)) {
    throw "no 'done' entry in history.jsonl"
}
Write-Host "✓ the goose showed up, ran an exercise, logged done and closed"

# Resident mode: autostart entry, and a second launch leaves the first one alone.
$agent = Start-Process $Exe -PassThru
Start-Sleep -Seconds 5
if ($agent.HasExited) { throw "tray agent exited (code $($agent.ExitCode))" }
$run = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue).Potyagus
if (-not $run) { throw "no autostart entry" }
Write-Host "autostart: $run"
$second = Start-Process $Exe -PassThru -Wait
if ($agent.HasExited) { throw "the second launch killed the first one" }
Write-Host "✓ tray agent runs, autostart set, second launch exited with $($second.ExitCode)"
Stop-Process $agent -Force
Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name Potyagus -ErrorAction SilentlyContinue
