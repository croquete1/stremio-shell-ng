# Diagnostic only (shell-ng#107): integrity of stremio-shell-ng across launch paths.
param([string]$Setup, [string]$DevApp)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\tok.ps1"
New-Item -ItemType Directory -Force C:\diag | Out-Null
$report = 'C:\diag\report.txt'
function R([string]$line) { $line | Tee-Object -Append $report | Out-Host }

R '== BASELINE'
R (Describe $PID 'runner-step')
Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object { R (Describe $_.ProcessId 'desktop-shell') }
$uac = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
R "UAC EnableLUA=$($uac.EnableLUA) ConsentPromptBehaviorAdmin=$($uac.ConsentPromptBehaviorAdmin) PromptOnSecureDesktop=$($uac.PromptOnSecureDesktop) EnableInstallerDetection=$($uac.EnableInstallerDetection) FilterAdministratorToken=$($uac.FilterAdministratorToken)"
R "OS $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"

R '== COMPATIBILITY STATE (before install)'
foreach ($key in 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers') {
    $values = (Get-ItemProperty $key -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* | Format-List | Out-String).Trim()
    R "$key : $(if ($values) { $values } else { '(none)' })"
}
R "IFEO stremio-shell-ng.exe: $(if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\stremio-shell-ng.exe') { 'PRESENT' } else { 'absent' })"

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Stremio'
$exe = Join-Path $installDir 'stremio-shell-ng.exe'

function Measure-Shell([string]$Tag, [int[]]$Exclude = @()) {
    $shell = WaitProcess 'stremio-shell-ng.exe' 40 $Exclude
    if (-not $shell) { R "$Tag | stremio-shell-ng did not start"; return 0 }
    Start-Sleep 8
    R (Describe $shell "$Tag SHELL")
    $runtime = Get-CimInstance Win32_Process -Filter "Name='stremio-runtime.exe'" | Where-Object { $_.ParentProcessId -eq $shell } | Select-Object -First 1
    if ($runtime) { R (Describe $runtime.ProcessId "$Tag CHILD(runtime)") }
    return $shell
}

R '== D. INSTALLER (user run, Medium desktop shell -> cmd -> start setup)'
foreach ($rep in 1..3) {
    KillStremio
    "@echo off`r`nstart `"`" /wait `"$Setup`" /SILENT /NOCANCEL /TASKS=runapp,desktopicon /LOG=`"C:\diag\setup-$rep.log`"`r`n" | Out-File -Encoding ascii C:\diag\install.cmd
    ShellLaunch 'C:\diag\install.cmd'
    $cmd = WaitProcess 'cmd.exe' 15
    $setupPid = WaitProcess (Split-Path $Setup -Leaf) 30
    if ($setupPid) { R (Describe $setupPid "D$rep INSTALLER") }
    $tmp = Get-CimInstance Win32_Process | Where-Object { $_.Name -like '*.tmp' } | Select-Object -First 1
    if ($tmp) { R (Describe $tmp.ProcessId "D$rep INSTALLER(.tmp)") }
    Measure-Shell "D$rep" | Out-Null
}
KillStremio

R '== COMPATIBILITY STATE (after install)'
foreach ($key in 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers', 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers') {
    $values = (Get-ItemProperty $key -ErrorAction SilentlyContinue | Select-Object * -ExcludeProperty PS* | Format-List | Out-String).Trim()
    R "$key : $(if ($values) { $values } else { '(none)' })"
}
$startLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Stremio.lnk'
$deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Stremio.lnk'
foreach ($lnk in $startLnk, $deskLnk) {
    if (Test-Path $lnk) {
        $bytes = [IO.File]::ReadAllBytes($lnk)
        $flags = [BitConverter]::ToUInt32($bytes, 0x14)
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        R "shortcut $lnk target=$($shortcut.TargetPath) RunAsAdmin(SLDF_RUNAS_USER)=$([bool]($flags -band 0x2000))"
    } else { R "shortcut $lnk missing" }
}
R "protocol stremio: $((Get-ItemProperty 'HKCU:\Software\Classes\stremio\shell\open\command' -ErrorAction SilentlyContinue).'(default)')"
R "manifest (mt.exe) of installed exe:"
& (Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\mt.exe' | Select-Object -Last 1).FullName -nologo "-inputresource:$exe;#1" -out:C:\diag\installed.manifest | Out-Null
R ((Get-Content C:\diag\installed.manifest -Raw) -replace '\s+', ' ')

R '== A/B/C/E. LAUNCH MATRIX (Medium desktop shell as the launcher)'
$paths = [ordered]@{ 'A-direct' = $exe; 'B-startmenu' = $startLnk; 'C-desktop' = $deskLnk }
foreach ($rep in 1..3) {
    foreach ($entry in $paths.GetEnumerator()) {
        KillStremio
        ShellLaunch $entry.Value
        Measure-Shell "$($entry.Key)#$rep" | Out-Null
    }
    KillStremio
    "@echo off`r`nstart `"`" `"stremio:///`"`r`n" | Out-File -Encoding ascii C:\diag\proto.cmd
    ShellLaunch 'C:\diag\proto.cmd'
    Measure-Shell "E-protocol#$rep" | Out-Null
}
KillStremio

R '== H. CONTROL: High parent (this runner step), with and without RUNASINVOKER'
$layers = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
foreach ($rep in 1..3) {
    KillStremio
    Start-Process -FilePath $exe
    Measure-Shell "H-high-parent#$rep" | Out-Null
}
New-Item -Force $layers | Out-Null
New-ItemProperty -Force -Path $layers -Name $exe -Value '~ RUNASINVOKER' | Out-Null
R "set HKCU Layers $exe = ~ RUNASINVOKER"
foreach ($rep in 1..3) {
    KillStremio
    Start-Process -FilePath $exe
    Measure-Shell "H-high-parent+RUNASINVOKER#$rep" | Out-Null
    KillStremio
    ShellLaunch $exe
    Measure-Shell "A-medium-parent+RUNASINVOKER#$rep" | Out-Null
}
Remove-ItemProperty -Path $layers -Name $exe
KillStremio

R '== U. UPDATER (Medium shell with a local update endpoint -> autoupdater-notif-clicked)'
$dev = Join-Path $DevApp 'stremio-shell-ng.exe'
foreach ($rep in 1..3) {
    KillStremio
    "@echo off`r`n`"$dev`" --autoupdater-endpoint http://127.0.0.1:8001/update.json --force-update`r`n" | Out-File -Encoding ascii C:\diag\dev.cmd
    ShellLaunch 'C:\diag\dev.cmd'
    $devShell = Measure-Shell "U$rep DEV-SHELL"
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and -not (Get-ChildItem $env:TEMP -Filter 'StremioSetup*.exe' -ErrorAction SilentlyContinue)) { Start-Sleep 1 }
    R "U$rep downloaded: $((Get-ChildItem $env:TEMP -Filter 'StremioSetup*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName)"
    Start-Sleep 3
    R "U$rep $(node "$PSScriptRoot\cdp.mjs" '["autoupdater-notif-clicked"]')"
    $setupPid = WaitProcess 'StremioSetup-v5.0.26_x64.exe' 30
    if ($setupPid) { R (Describe $setupPid "U$rep INSTALLER") }
    $tmp = Get-CimInstance Win32_Process | Where-Object { $_.Name -like '*.tmp' } | Select-Object -First 1
    if ($tmp) { R (Describe $tmp.ProcessId "U$rep INSTALLER(.tmp)") }
    Measure-Shell "U$rep AFTER-UPDATE" @($devShell) | Out-Null
    Get-ChildItem $env:TEMP -Filter 'StremioSetup*.exe' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
KillStremio

R '== X. EXTERNAL PLAYER (play-external M3U -> cmd /C start -> .m3u handler)'
$m3u = 'data:application/octet-stream;charset=utf-8;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("#EXTM3U`n#EXTINF:0`nhttp://127.0.0.1:8001/test.mp4"))
foreach ($mode in 'medium', 'high') {
    foreach ($rep in 1..3) {
        KillStremio
        if ($mode -eq 'medium') { "@echo off`r`n`"$dev`"`r`n" | Out-File -Encoding ascii C:\diag\dev.cmd; ShellLaunch 'C:\diag\dev.cmd' } else { Start-Process -FilePath $dev }
        Measure-Shell "X-$mode#$rep" | Out-Null
        Start-Sleep 12
        R "X-$mode#$rep $(node "$PSScriptRoot\cdp.mjs" ('["play-external",' + (ConvertTo-Json $m3u) + ']'))"
        $probe = WaitProcess 'm3uprobe.exe' 20
        if ($probe) {
            R (Describe $probe "X-$mode#$rep PLAYER")
            $cmdParent = (Get-CimInstance Win32_Process -Filter "ProcessId=$probe").ParentProcessId
            R (Describe $cmdParent "X-$mode#$rep PLAYER-PARENT")
        } else { R "X-$mode#$rep external player did not start" }
    }
}
KillStremio
R '== DONE'
