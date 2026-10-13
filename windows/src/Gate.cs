// "Should we nudge at all?" — the Windows side of skipReason() in src/main.swift:
// pause, locked screen, working hours, weekends, calls, blocklisted foreground app.

using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Potyagus;

/// Why we should not show the overlay right now. `Retriable` marks the reasons that pass
/// on their own — worth waiting out rather than writing off the whole hour.
sealed record Skip(string Reason, bool Retriable);

static class Gate
{
    public static async Task<Skip?> SkipReason(Config cfg, bool force)
    {
        if (force) return null;
        if (Pause.Until() is DateTime until)
            return new Skip($"на паузі до {until:HH\\:mm}", false);
        if (SessionLock.IsLocked) return new Skip("екран заблоковано", false);
        var now = DateTime.Now;
        if (now.Hour < cfg.StartHour || now.Hour >= cfg.EndHour)
            return new Skip($"поза робочими годинами ({cfg.StartHour}:00–{cfg.EndHour}:00)", false);
        if (cfg.WeekdaysOnly && now.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday)
            return new Skip("вихідний", false);
        if (await Calls.InProgress(cfg)) return new Skip("іде дзвінок", true);
        if (BlockedByFrontApp(cfg) is string app)
            return new Skip($"активний застосунок у блоклисті ({app})", true);
        return null;
    }

    public static string? BlockedByFrontApp(Config cfg)
    {
        var name = Foreground.ProcessName();
        if (name == null) return null;
        return cfg.BlockApps.Any(b => string.Equals(StripExe(b), name, StringComparison.OrdinalIgnoreCase)) ? name : null;
    }

    static string StripExe(string s) => s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? s[..^4] : s;
}

/// Locked workstation. Session events catch lock/unlock while we run; LogonUI covers the
/// case where we started (or the event was missed) while already locked.
static class SessionLock
{
    static bool locked;

    public static void Start()
    {
        SystemEvents.SessionSwitch += (_, e) =>
        {
            if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.ConsoleDisconnect
                         or SessionSwitchReason.RemoteDisconnect) locked = true;
            if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.ConsoleConnect
                         or SessionSwitchReason.RemoteConnect) locked = false;
        };
    }

    public static bool IsLocked
    {
        get
        {
            if (locked) return true;
            try { return Process.GetProcessesByName("LogonUI").Length > 0; } catch { return false; }
        }
    }
}

static class Foreground
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    public static string? ProcessName()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;
        GetWindowThreadProcessId(hwnd, out var pid);
        try { using var p = Process.GetProcessById((int)pid); return p.ProcessName; }
        catch { return null; }
    }
}

/// Tell a call apart from dictation, the same way the Mac app does: a call holds the
/// microphone *and* plays sound; dictation holds only the microphone. Then look again a few
/// seconds later, because dictation comes in bursts while a call stays open.
static class Calls
{
    public static async Task<bool> InProgress(Config cfg)
    {
        if (!cfg.SkipDuringCalls || !Mic.InUse()) return false;
        if (cfg.RequireOutputForCall && !Speakers.InUse()) return false;   // mic only → dictation
        if (cfg.ConfirmCallSeconds <= 0) return true;
        await Task.Delay(TimeSpan.FromSeconds(cfg.ConfirmCallSeconds));
        if (!Mic.InUse()) return false;
        return !cfg.RequireOutputForCall || Speakers.InUse();
    }
}

/// Who is holding the microphone right now, read from the same registry store that drives
/// Windows' own "microphone in use" indicator. Reading it needs no permission and never prompts.
/// An app is live while LastUsedTimeStart is set and LastUsedTimeStop is 0.
static class Mic
{
    const string Root = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    public static bool InUse() => Users().Count > 0;

    public static List<string> Users()
    {
        var live = new List<string>();
        try
        {
            using var root = Registry.CurrentUser.OpenSubKey(Root);
            if (root == null) return live;
            Collect(root, live, depth: 0);
        }
        catch (Exception e) { Log.Write("mic: " + e.Message); }
        return live;
    }

    static void Collect(RegistryKey key, List<string> live, int depth)
    {
        foreach (var name in key.GetSubKeyNames())
        {
            using var sub = key.OpenSubKey(name);
            if (sub == null) continue;
            if (sub.GetValue("LastUsedTimeStop") is long stop)
            {
                var start = sub.GetValue("LastUsedTimeStart") as long? ?? 0;
                if (stop == 0 && start != 0) live.Add(Pretty(name));
            }
            // Desktop apps sit one level deeper, under "NonPackaged".
            else if (depth == 0) Collect(sub, live, depth + 1);
        }
    }

    /// "C:#Program Files#Zoom#bin#Zoom.exe" → "Zoom.exe"; packaged ids stay as they are.
    static string Pretty(string key)
    {
        var i = key.LastIndexOf('#');
        return i >= 0 ? key[(i + 1)..] : key;
    }
}

/// Is anything playing sound? True when any audio session on any active output device is
/// in the Active state — the WASAPI counterpart of CoreAudio's "device is running somewhere".
static class Speakers
{
    public static bool InUse() => ActiveSessions().Count > 0;

    public static List<string> ActiveSessions()
    {
        var found = new List<string>();
        try
        {
            var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
            Check(en.EnumAudioEndpoints(EDataFlow.Render, DeviceStateActive, out var devices));
            Check(devices.GetCount(out var count));
            for (uint i = 0; i < count; i++)
            {
                Check(devices.Item(i, out var dev));
                var iid = typeof(IAudioSessionManager2).GUID;
                Check(dev.Activate(ref iid, ClsCtxAll, IntPtr.Zero, out var obj));
                var mgr = (IAudioSessionManager2)obj;
                Check(mgr.GetSessionEnumerator(out var sessions));
                Check(sessions.GetCount(out var n));
                for (int s = 0; s < n; s++)
                {
                    Check(sessions.GetSession(s, out var ctl));
                    Check(ctl.GetState(out var state));
                    if (state == AudioSessionState.Active)
                    {
                        var pid = ctl is IAudioSessionControl2 c2 && c2.GetProcessId(out var p) == 0 ? p : 0;
                        found.Add(ProcName(pid));
                    }
                }
            }
        }
        catch (Exception e) { Log.Write("speakers: " + e.Message); }
        return found;
    }

    static string ProcName(uint pid)
    {
        if (pid == 0) return "система";
        try { using var p = Process.GetProcessById((int)pid); return p.ProcessName; } catch { return $"pid {pid}"; }
    }

    static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }

    const uint DeviceStateActive = 0x1;
    const int ClsCtxAll = 0x17;

    enum EDataFlow { Render = 0, Capture = 1, All = 2 }
    enum AudioSessionState { Inactive = 0, Active = 1, Expired = 2 }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorCom { }

    // Vtable order matters: every method up to the last one we call is declared, in order.
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(EDataFlow flow, uint stateMask, out IMMDeviceCollection devices);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
                                   [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2
    {
        [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, uint flags, out IntPtr control);   // IAudioSessionManager
        [PreserveSig] int GetSimpleAudioVolume(IntPtr sessionGuid, uint flags, out IntPtr volume);       // IAudioSessionManager
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl session);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl
    {
        [PreserveSig] int GetState(out AudioSessionState state);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2
    {
        // IAudioSessionControl
        [PreserveSig] int GetState(out AudioSessionState state);
        [PreserveSig] int GetDisplayName(out IntPtr name);
        [PreserveSig] int SetDisplayName(IntPtr name, IntPtr ctx);
        [PreserveSig] int GetIconPath(out IntPtr path);
        [PreserveSig] int SetIconPath(IntPtr path, IntPtr ctx);
        [PreserveSig] int GetGroupingParam(out Guid group);
        [PreserveSig] int SetGroupingParam(ref Guid group, IntPtr ctx);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
        // IAudioSessionControl2
        [PreserveSig] int GetSessionIdentifier(out IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
    }
}
