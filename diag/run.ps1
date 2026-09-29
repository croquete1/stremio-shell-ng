# Diagnostic only (stremio-bugs#2827): one repetition. Surfaces: board, player, picker, links.
param([string]$Exe, [string]$Surface, [string]$Label, [string]$PlayerHash, [string]$Srt)
$ErrorActionPreference = 'Continue'
$out = Join-Path $PWD "out\$Label"
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $env:TEMP 'diag2827.log'
Remove-Item $log -ErrorAction SilentlyContinue

Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public static class Win {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    public static void Shot(string path) {
        var b = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        using (var bmp = new Bitmap(b.Width, b.Height)) {
            using (var g = Graphics.FromImage(bmp)) { g.CopyFromScreen(b.Location, Point.Empty, b.Size); }
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
"@

$browsersBefore = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Select-Object -ExpandProperty ProcessId)
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=9333'
$shell = Start-Process -FilePath $Exe -ArgumentList '--no-splash' -PassThru -RedirectStandardOutput "$out\stdout.txt" -RedirectStandardError "$out\stderr.txt"
"surface=$Surface label=$Label exe=$Exe pid=$($shell.Id)" | Tee-Object "$out\steps.txt"
node diag\cdp.mjs wait | Tee-Object -Append "$out\steps.txt"
Start-Sleep 20
node diag\cdp.mjs setup | Tee-Object -Append "$out\steps.txt"

if ($Surface -in @('player', 'picker')) {
    node diag\cdp.mjs hash $PlayerHash | Tee-Object -Append "$out\steps.txt"
    Start-Sleep 20
}
[Win]::Shot("$out\before.png")

if ($Surface -eq 'links') {
    node diag\cdp.mjs open 'https://www.stremio.com/' | Tee-Object -Append "$out\steps.txt"
    Start-Sleep 2
    node diag\cdp.mjs open 'https://example.com/page' | Tee-Object -Append "$out\steps.txt"
    Start-Sleep 3
} elseif ($Surface -eq 'picker') {
    node diag\cdp.mjs picker $Srt | Tee-Object -Append "$out\steps.txt"
    Start-Sleep 6
} else {
    $shell.Refresh()
    $hwnd = $shell.MainWindowHandle
    $rect = New-Object Win+RECT
    [Win]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    [Win]::SetForegroundWindow($hwnd) | Out-Null
    $x = [int](($rect.Left + $rect.Right) / 2); $y = [int](($rect.Top + $rect.Bottom) / 2)
    "window rect=$($rect.Left),$($rect.Top),$($rect.Right),$($rect.Bottom) drop=$x,$y" | Tee-Object -Append "$out\steps.txt"
    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File diag\drag.ps1 -File $Srt -X $x -Y $y | Tee-Object -Append "$out\steps.txt"
    Start-Sleep 6
}

node diag\cdp.mjs state | Out-File -Encoding utf8 "$out\state.json"
[Win]::Shot("$out\after.png")
$browsersAfter = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $browsersBefore -notcontains $_.ProcessId } | ForEach-Object { $_.CommandLine })
"new msedge.exe processes: $($browsersAfter.Count)" | Tee-Object -Append "$out\steps.txt"
$browsersAfter | Select-Object -First 3 | Tee-Object -Append "$out\steps.txt"

taskkill /PID $shell.Id /T /F | Out-Null
Start-Sleep 3
if (Test-Path $log) { Copy-Item $log "$out\handlers.log" } else { 'no handler activity' | Out-File "$out\handlers.log" }
"--- handlers.log"; Get-Content "$out\handlers.log"
"--- state.json"; Get-Content "$out\state.json"
