// One borderless, topmost window per monitor, each hosting web/overlay.html in WebView2.
// The page is untouched: a tiny shim recreates window.webkit.messageHandlers.rozimnys
// (what WKWebView gives the Mac app) on top of WebView2's chrome.webview.postMessage.

using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace Potyagus;

sealed class OverlayForm : Form
{
    /// Served from a virtual https host rather than file:// so the page, clips and sounds share
    /// one origin — the chroma-key canvas reads video pixels, and file:// would taint it.
    public const string Host = "potyagus.local";

    const string Shim = """
        (() => {
          const post = m => window.chrome.webview.postMessage(m);
          window.webkit = { messageHandlers: { rozimnys: { postMessage: post } } };
          // -apple-system / SF Pro don't exist here; Segoe UI is Windows' closest match.
          document.addEventListener("DOMContentLoaded", () => {
            const s = document.createElement("style");
            s.textContent = 'body{font-family:"Segoe UI Variable Display","Segoe UI",-apple-system,sans-serif}';
            document.head.appendChild(s);
          });
        })();
        """;

    public readonly Screen Screen;
    public readonly bool Primary;
    readonly WebView2 web = new();
    readonly string payloadJson;
    bool allowClose;

    /// Raised with the page's message: {action, minutes?, elapsed?, started?}.
    public event Action<OverlayForm, JsonObject>? Message;

    public OverlayForm(Screen screen, bool primary, string payloadJson)
    {
        Screen = screen;
        Primary = primary;
        this.payloadJson = payloadJson;

        Text = "Потягусь";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        BackColor = Color.FromArgb(0x7D, 0xB2, 0x62);   // the lawn, so nothing flashes white
        Bounds = screen.Bounds;

        web.Dock = DockStyle.Fill;
        web.DefaultBackgroundColor = BackColor;
        Controls.Add(web);
    }

    public async Task LoadAsync(CoreWebView2Environment env)
    {
        await web.EnsureCoreWebView2Async(env);
        var core = web.CoreWebView2;
        var s = core.Settings;
        s.AreDefaultContextMenusEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false;
        s.IsZoomControlEnabled = false;
        s.IsPinchZoomEnabled = false;
        s.IsSwipeNavigationEnabled = false;
        s.IsStatusBarEnabled = false;
        s.AreDevToolsEnabled = Environment.GetEnvironmentVariable("POTYAGUS_DEVTOOLS") == "1";

        core.SetVirtualHostNameToFolderMapping(Host, Paths.Web, CoreWebView2HostResourceAccessKind.Allow);
        await core.AddScriptToExecuteOnDocumentCreatedAsync(Shim);

        core.WebMessageReceived += (_, e) =>
        {
            try
            {
                if (JsonNode.Parse(e.WebMessageAsJson) is JsonObject msg) Message?.Invoke(this, msg);
            }
            catch (Exception ex) { Log.Write("message: " + ex.Message); }
        };
        // Same moment as WKNavigationDelegate didFinish on the Mac: hand the page its payload.
        core.NavigationCompleted += async (_, e) =>
        {
            if (!e.IsSuccess) { Log.Write($"overlay failed to load: {e.WebErrorStatus}"); return; }
            await core.ExecuteScriptAsync($"window.rozimnysInit({payloadJson})");
            // Focus again once the page exists: before that WebView2 has nowhere to put it,
            // and without it Space / Enter go to whatever app was in front.
            if (Primary) TakeFocus();
        };
        // Links never leave the overlay.
        core.NewWindowRequested += (_, e) => e.Handled = true;

        core.Navigate($"https://{Host}/overlay.html");
    }

    /// Topmost over everything on its monitor, including the taskbar; the primary one also
    /// takes keyboard focus so Space / Enter start the exercise like on the Mac.
    public void ShowOverlay()
    {
        Show();
        Native.SetWindowPos(Handle, Native.HwndTopmost, Screen.Bounds.X, Screen.Bounds.Y,
                            Screen.Bounds.Width, Screen.Bounds.Height, Native.SwpShowWindow);
        if (Primary) TakeFocus();
    }

    void TakeFocus()
    {
        Native.ForceForeground(Handle);
        Activate();
        web.Focus();
    }

    /// Moving between monitors with different scaling must not resize us off the screen.
    protected override void OnDpiChanged(DpiChangedEventArgs e)
    {
        base.OnDpiChanged(e);
        Bounds = Screen.Bounds;
    }

    /// Alt+F4 doesn't get rid of the goose — the page has its own skip / snooze buttons.
    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!allowClose && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; return; }
        base.OnFormClosing(e);
    }

    public void CloseForGood()
    {
        allowClose = true;
        Close();
        web.Dispose();
    }

    /// No activation flicker in Alt+Tab, and a tool window never shows up in the taskbar.
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= Native.WsExToolWindow;
            return cp;
        }
    }
}

static class Native
{
    public static readonly IntPtr HwndTopmost = new(-1);
    public const uint SwpShowWindow = 0x0040;
    public const int WsExToolWindow = 0x00000080;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    const byte VkMenu = 0x12;
    const uint KeyEventFKeyUp = 0x0002;

    /// Windows refuses SetForegroundWindow from a background process unless it is attached to
    /// the input of the current foreground thread — the overlay is the one time we want focus.
    public static void ForceForeground(IntPtr hwnd)
    {
        var fg = GetForegroundWindow();
        var fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
        var me = GetCurrentThreadId();
        var attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        // Holding Alt lifts the foreground lock for this process. It is released only after we
        // are in front, so the app we take over from never sees a lone Alt tap (no menu pops up).
        keybd_event(VkMenu, 0, 0, UIntPtr.Zero);
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        keybd_event(VkMenu, 0, KeyEventFKeyUp, UIntPtr.Zero);
        if (attached) AttachThreadInput(me, fgThread, false);
    }
}
