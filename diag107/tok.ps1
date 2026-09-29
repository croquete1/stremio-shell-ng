# Diagnostic only (shell-ng#107): token integrity helpers. Dot-source this file.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class Tok {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(int pid, out int session);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr buffer, int length, out int returned);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);

    public static string Info(int pid) {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) return "open-process-failed err=" + Marshal.GetLastWin32Error();
        IntPtr token;
        if (!OpenProcessToken(process, 0x000A, out token)) { CloseHandle(process); return "open-token-failed"; }
        int length;
        GetTokenInformation(token, 25, IntPtr.Zero, 0, out length);
        IntPtr label = Marshal.AllocHGlobal(length);
        GetTokenInformation(token, 25, label, length, out length);
        IntPtr sid = Marshal.ReadIntPtr(label);
        int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
        int rid = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
        IntPtr value = Marshal.AllocHGlobal(4);
        GetTokenInformation(token, 20, value, 4, out length);
        int elevated = Marshal.ReadInt32(value);
        GetTokenInformation(token, 18, value, 4, out length);
        int type = Marshal.ReadInt32(value);
        string user;
        try { user = new System.Security.Principal.WindowsIdentity(token).Name; } catch { user = "?"; }
        int session;
        ProcessIdToSessionId(pid, out session);
        Marshal.FreeHGlobal(label); Marshal.FreeHGlobal(value);
        CloseHandle(token); CloseHandle(process);
        string level = rid >= 0x4000 ? "SYSTEM" : rid >= 0x3000 ? "HIGH" : rid >= 0x2000 ? "MEDIUM" : rid >= 0x1000 ? "LOW" : "UNTRUSTED";
        string typeName = type == 1 ? "Default" : type == 2 ? "Full" : type == 3 ? "Limited" : type.ToString();
        return level + " (rid 0x" + rid.ToString("x") + ", elevated=" + elevated + ", type=" + typeName + ", user=" + user + ", session=" + session + ")";
    }
}
"@

function Describe([int]$ProcessId, [string]$Tag) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId"
    if (-not $p) { return "$Tag pid=$ProcessId gone" }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)"
    $parentInfo = if ($parent) { "$($parent.Name)#$($parent.ProcessId) $([Tok]::Info([int]$parent.ProcessId))" } else { "#$($p.ParentProcessId) (exited)" }
    "$Tag | $($p.Name)#$ProcessId $([Tok]::Info($ProcessId)) | PARENT $parentInfo | cmd=$(([string]$p.CommandLine).Substring(0, [Math]::Min(160, ([string]$p.CommandLine).Length)))"
}

function WaitProcess([string]$Name, [int]$Seconds, [int[]]$Exclude = @()) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $found = Get-CimInstance Win32_Process -Filter "Name='$Name'" | Where-Object { $Exclude -notcontains $_.ProcessId } | Select-Object -First 1
        if ($found) { return [int]$found.ProcessId }
        Start-Sleep -Milliseconds 300
    }
    return 0
}

function KillStremio {
    foreach ($name in 'stremio-shell-ng.exe', 'stremio-runtime.exe', 'm3uprobe.exe') {
        Get-CimInstance Win32_Process -Filter "Name='$name'" | ForEach-Object { taskkill /PID $_.ProcessId /T /F 2>$null | Out-Null }
    }
    Start-Sleep 3
}

# Launch through the interactive desktop shell (explorer.exe), the way a user double-click does.
function ShellLaunch([string]$Target) {
    Start-Process -FilePath explorer.exe -ArgumentList "`"$Target`""
}
