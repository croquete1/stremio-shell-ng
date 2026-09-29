# Diagnostic only (shell-ng#107): High-parent control, run from the elevated runner account.
param([string]$Exe, [string]$DevApp, [string]$Node)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\tok.ps1"
$report = 'C:\diag\report.txt'
function Log([string]$line) { $line | Tee-Object -Append $report | Out-Host }

function Measure-Shell([string]$Tag) {
    $shell = WaitProcess 'stremio-shell-ng.exe' 40
    if (-not $shell) { Log "$Tag | stremio-shell-ng did not start"; return }
    Start-Sleep 8
    Log (Describe $shell "$Tag SHELL")
    $runtime = Get-CimInstance Win32_Process -Filter "Name='stremio-runtime.exe'" | Where-Object { $_.ParentProcessId -eq $shell } | Select-Object -First 1
    if ($runtime) { Log (Describe $runtime.ProcessId "$Tag CHILD(runtime)") }
}

Log '== H. CONTROL: High parent (elevated runner account)'
Log (Describe $PID 'control-driver')
foreach ($rep in 1..3) { KillStremio; Start-Process -FilePath $Exe; Measure-Shell "H-high-parent#$rep" }
$layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
New-Item -Force $layers | Out-Null
New-ItemProperty -Force -Path $layers -Name $Exe -Value '~ RUNASINVOKER' | Out-Null
Log "set HKCU Layers $Exe = ~ RUNASINVOKER (runner account)"
foreach ($rep in 1..3) { KillStremio; Start-Process -FilePath $Exe; Measure-Shell "H-high-parent+RUNASINVOKER#$rep" }
Remove-ItemProperty -Path $layers -Name $Exe
KillStremio

Log '== X-high. EXTERNAL PLAYER from a High shell'
New-Item -Force 'HKCU:\Software\Classes\.m3u' -Value 'Diag.m3u' | Out-Null
New-Item -Force 'HKCU:\Software\Classes\Diag.m3u\shell\open\command' -Value '"C:\diag\m3uprobe.exe" "%1"' | Out-Null
$dev = Join-Path $DevApp 'stremio-shell-ng.exe'
$m3u = 'data:application/octet-stream;charset=utf-8;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("#EXTM3U`n#EXTINF:0`nhttp://127.0.0.1:8001/test.mp4"))
foreach ($rep in 1..3) {
    KillStremio
    Start-Process -FilePath $dev
    Measure-Shell "X-high#$rep"
    Start-Sleep 12
    Log "X-high#$rep $(& $Node "$PSScriptRoot\cdp.mjs" ('["play-external",' + (ConvertTo-Json $m3u) + ']'))"
    $probe = WaitProcess 'm3uprobe.exe' 20
    if ($probe) { Log (Describe $probe "X-high#$rep PLAYER") } else { Log "X-high#$rep external player did not start" }
}
KillStremio
Log '== DONE (control)'
