# Diagnostic only (shell-ng#107): runs INSIDE a standard (non-admin) user's logon, i.e. from a Medium parent.
# Launches use ShellExecute (Start-Process), the same API Explorer uses for a double-click.
param([string]$Setup, [string]$DevApp, [string]$Node)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\tok.ps1"
$report = 'C:\diag\report.txt'
function Log([string]$line) { $line | Tee-Object -Append $report | Out-Host }

Log '== BASELINE (standard user logon)'
Log (Describe $PID 'driver')
Log "whoami: $(whoami)  admin-group: $([bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))"
$uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
Log "UAC EnableLUA=$($uac.EnableLUA) ConsentPromptBehaviorAdmin=$($uac.ConsentPromptBehaviorAdmin) ConsentPromptBehaviorUser=$($uac.ConsentPromptBehaviorUser) EnableInstallerDetection=$($uac.EnableInstallerDetection)"

function Compat([string]$When) {
    Log "== COMPATIBILITY STATE ($When)"
    foreach ($key in 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers') {
        $values = (Get-ItemProperty $key -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* | Format-List | Out-String).Trim()
        Log "$key : $(if ($values) { $values } else { '(none)' })"
    }
    Log "IFEO stremio-shell-ng.exe: $(if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\stremio-shell-ng.exe') { 'PRESENT' } else { 'absent' })"
}
Compat 'before install'

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Stremio'
$exe = Join-Path $installDir 'stremio-shell-ng.exe'

function Measure-Shell([string]$Tag, [int[]]$Exclude = @()) {
    $shell = WaitProcess 'stremio-shell-ng.exe' 40 $Exclude
    if (-not $shell) { Log "$Tag | stremio-shell-ng did not start"; return 0 }
    Start-Sleep 8
    Log (Describe $shell "$Tag SHELL")
    $runtime = Get-CimInstance Win32_Process -Filter "Name='stremio-runtime.exe'" | Where-Object { $_.ParentProcessId -eq $shell } | Select-Object -First 1
    if ($runtime) { Log (Describe $runtime.ProcessId "$Tag CHILD(runtime)") }
    return $shell
}

Log '== D. INSTALLER run by the user (ShellExecute from a Medium parent), task runapp'
foreach ($rep in 1..3) {
    KillStremio
    Start-Process -FilePath $Setup -ArgumentList @('/SILENT', '/NOCANCEL', '/TASKS=runapp,desktopicon', "/LOG=C:\diag\setup-$rep.log")
    $setupPid = WaitProcess (Split-Path $Setup -Leaf) 30
    if ($setupPid) { Log (Describe $setupPid "D$rep INSTALLER") }
    $tmp = WaitProcess 'StremioSetup-v5.0.26_x64.tmp' 20
    if ($tmp) { Log (Describe $tmp "D$rep INSTALLER(.tmp)") }
    Measure-Shell "D$rep" | Out-Null
}
KillStremio
Compat 'after install'

$startLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Stremio.lnk'
$deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Stremio.lnk'
foreach ($lnk in $startLnk, $deskLnk) {
    if (Test-Path $lnk) {
        $flags = [BitConverter]::ToUInt32([IO.File]::ReadAllBytes($lnk), 0x14)
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        Log "shortcut $lnk target=$($shortcut.TargetPath) RunAsAdmin(SLDF_RUNAS_USER)=$([bool]($flags -band 0x2000))"
    } else { Log "shortcut $lnk missing" }
}
Log "protocol stremio: $((Get-ItemProperty 'HKCU:\Software\Classes\stremio\shell\open\command' -ErrorAction SilentlyContinue).'(default)')"

Log '== A/B/C/E. LAUNCH MATRIX (Medium parent, ShellExecute)'
$paths = [ordered]@{ 'A-direct' = $exe; 'B-startmenu' = $startLnk; 'C-desktop' = $deskLnk; 'E-protocol' = 'stremio:///' }
foreach ($rep in 1..3) {
    foreach ($entry in $paths.GetEnumerator()) {
        KillStremio
        Start-Process -FilePath $entry.Value
        Measure-Shell "$($entry.Key)#$rep" | Out-Null
    }
}
KillStremio

Log '== A+RUNASINVOKER (Medium parent, HKCU compatibility layer set)'
$layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
New-Item -Force $layers | Out-Null
New-ItemProperty -Force -Path $layers -Name $exe -Value '~ RUNASINVOKER' | Out-Null
foreach ($rep in 1..3) { KillStremio; Start-Process -FilePath $exe; Measure-Shell "A-RUNASINVOKER#$rep" | Out-Null }
Remove-ItemProperty -Path $layers -Name $exe
KillStremio

Log '== U. UPDATER (Medium shell, local update endpoint, autoupdater-notif-clicked -> setup /TASKS=runapp)'
$dev = Join-Path $DevApp 'stremio-shell-ng.exe'
foreach ($rep in 1..3) {
    KillStremio
    Get-ChildItem $env:TEMP -Filter 'StremioSetup*.exe' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $dev -ArgumentList @('--autoupdater-endpoint', 'http://127.0.0.1:8001/update.json', '--force-update')
    $devShell = Measure-Shell "U$rep DEV-SHELL"
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline -and -not (Get-ChildItem $env:TEMP -Filter 'StremioSetup*.exe' -ErrorAction SilentlyContinue)) { Start-Sleep 1 }
    Log "U$rep downloaded: $((Get-ChildItem $env:TEMP -Filter 'StremioSetup*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)"
    Start-Sleep 5
    Log "U$rep $(& $Node "$PSScriptRoot\cdp.mjs" '["autoupdater-notif-clicked"]')"
    $setupPid = WaitProcess 'StremioSetup-v5.0.26_x64.exe' 30
    if ($setupPid) { Log (Describe $setupPid "U$rep INSTALLER") }
    $tmp = WaitProcess 'StremioSetup-v5.0.26_x64.tmp' 20
    if ($tmp) { Log (Describe $tmp "U$rep INSTALLER(.tmp)") }
    Measure-Shell "U$rep AFTER-UPDATE" @($devShell) | Out-Null
}
KillStremio

Log '== X. EXTERNAL PLAYER (Medium shell, play-external M3U -> cmd /C start -> .m3u handler)'
New-Item -Force 'HKCU:\Software\Classes\.m3u' -Value 'Diag.m3u' | Out-Null
New-Item -Force 'HKCU:\Software\Classes\Diag.m3u\shell\open\command' -Value '"C:\diag\m3uprobe.exe" "%1"' | Out-Null
$m3u = 'data:application/octet-stream;charset=utf-8;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("#EXTM3U`n#EXTINF:0`nhttp://127.0.0.1:8001/test.mp4"))
foreach ($rep in 1..3) {
    KillStremio
    Start-Process -FilePath $dev
    Measure-Shell "X-medium#$rep" | Out-Null
    Start-Sleep 12
    Log "X-medium#$rep $(& $Node "$PSScriptRoot\cdp.mjs" ('["play-external",' + (ConvertTo-Json $m3u) + ']'))"
    $probe = WaitProcess 'm3uprobe.exe' 20
    if ($probe) { Log (Describe $probe "X-medium#$rep PLAYER") } else { Log "X-medium#$rep external player did not start" }
}
KillStremio
Log '== DONE (standard user)'
