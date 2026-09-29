# Diagnostic only (shell-ng#107): external player control. Run once as the standard user (Medium) and once elevated (High).
param([string]$Mode, [string]$DevApp, [string]$Node)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\tok.ps1"
$report = 'C:\diag\report.txt'
function Log([string]$line) { $line | Tee-Object -Append $report | Out-Host }
function B64([string]$text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
function Measure-Shell([string]$Tag) {
    $shell = WaitProcess 'stremio-shell-ng.exe' 40
    if (-not $shell) { Log "$Tag | stremio-shell-ng did not start"; return }
    Start-Sleep 8
    Log (Describe $shell "$Tag SHELL")
}

Log "== X-$Mode. EXTERNAL PLAYER (VLC path: Command::new via App Paths; M3U path: cmd /C start playlist.m3u)"
Log (Describe $PID "X-$Mode driver")
# The shell looks up vlc.exe through HKCU App Paths first; point it at a harmless probe process.
New-Item -Force 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe' -Value 'C:\diag\m3uprobe.exe' | Out-Null
$dev = Join-Path $DevApp 'stremio-shell-ng.exe'
$m3u = 'data:application/octet-stream;charset=utf-8;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("#EXTM3U`n#EXTINF:0`nhttp://127.0.0.1:8001/test.mp4"))
foreach ($rep in 1..3) {
    KillStremio
    Start-Process -FilePath $dev
    Measure-Shell "X-$Mode#$rep"
    Start-Sleep 12
    Log "X-$Mode#$rep VLC $(& $Node "$PSScriptRoot\cdp.mjs" (B64 '["play-external","vlc://http://127.0.0.1:8001/test.mp4"]'))"
    $probe = WaitProcess 'm3uprobe.exe' 20
    if ($probe) { Log (Describe $probe "X-$Mode#$rep VLC-PLAYER") } else { Log "X-$Mode#$rep VLC player did not start" }
    taskkill /IM m3uprobe.exe /F 2>$null | Out-Null
    $before = @(Get-CimInstance Win32_Process | Select-Object -ExpandProperty ProcessId)
    Log "X-$Mode#$rep M3U $(& $Node "$PSScriptRoot\cdp.mjs" (B64 ('["play-external",' + (ConvertTo-Json $m3u) + ']')))"
    $deadline = (Get-Date).AddSeconds(15)
    $seen = @{}
    while ((Get-Date) -lt $deadline) {
        Get-CimInstance Win32_Process | Where-Object { $before -notcontains $_.ProcessId -and -not $seen.ContainsKey($_.ProcessId) -and ([string]$_.CommandLine -match 'playlist\.m3u') } | ForEach-Object {
            $seen[$_.ProcessId] = $true
            Log (Describe $_.ProcessId "X-$Mode#$rep M3U-OPENER")
        }
        Start-Sleep -Milliseconds 250
    }
    if ($seen.Count -eq 0) { Log "X-$Mode#$rep M3U: no process with playlist.m3u seen" }
}
KillStremio
Log "== DONE (X-$Mode)"
