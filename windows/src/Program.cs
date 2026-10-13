// Потягусь для Windows — a goose that blocks the screen until you stretch.
// Launched plainly (double-click, or at login) it stays resident in the tray, adds itself to
// autostart and nudges on its own schedule. With --now/--force it shows the overlay once and
// quits; --check/--devices just print, like the Mac build.

using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;

namespace Potyagus;

static class Program
{
    const string InstanceName = @"Local\com.alina.potyagus";
    const string ReopenName = @"Local\com.alina.potyagus.reopen";

    [STAThread]
    static int Main(string[] args)
    {
        bool Has(string a) => args.Any(x => string.Equals(x, a, StringComparison.OrdinalIgnoreCase));
        var force = Has("--now") || Has("--force");

        if (Has("--devices") || Has("--check"))
        {
            AttachConsole(-1);
            Console.OutputEncoding = System.Text.Encoding.UTF8;
            Console.WriteLine();
            if (Has("--devices")) Devices(); else Check();
            return 0;
        }

        ApplicationConfiguration.Initialize();

        try { CoreWebView2Environment.GetAvailableBrowserVersionString(); }
        catch (WebView2RuntimeNotFoundException)
        {
            MessageBox.Show("Потягусю потрібен Microsoft Edge WebView2 Runtime. Він є в Windows 11 і в оновленій Windows 10; " +
                            "якщо ні — встанови його з https://go.microsoft.com/fwlink/p/?LinkId=2124703 і запусти ще раз.",
                            "Потягусь", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 2;
        }

        try { Library.Load(); }
        catch (Exception e)
        {
            MessageBox.Show("Не знайшов exercises.json поруч із Potyagus.exe: " + e.Message, "Потягусь");
            return 2;
        }

        if (force)
        {
            var once = new Agent(agentMode: false);
            AfterStart(() => once.RunOnce(force: true));
            Application.Run(once);
            return 0;
        }

        // Only one resident goose. A second launch pings the first one to bring its icon back.
        using var mutex = new Mutex(true, InstanceName, out var first);
        using var reopen = new EventWaitHandle(false, EventResetMode.AutoReset, ReopenName);
        if (!first)
        {
            reopen.Set();
            return 0;
        }

        var agent = new Agent(agentMode: true);
        var ui = new Control();   // a handle on the UI thread to marshal the reopen ping onto
        ui.CreateControl();
        var listener = new Thread(() =>
        {
            while (true)
            {
                reopen.WaitOne();
                try { ui.BeginInvoke(agent.Reopened); } catch { return; }
            }
        }) { IsBackground = true };
        listener.Start();

        AfterStart(agent.StartAgent);
        Application.Run(agent);
        GC.KeepAlive(mutex);
        return 0;
    }

    /// Run once the message loop is up, so every await resumes on the UI thread.
    static void AfterStart(Action act)
    {
        var t = new System.Windows.Forms.Timer { Interval = 1 };
        t.Tick += (_, _) => { t.Stop(); t.Dispose(); act(); };
        t.Start();
    }

    // `potyagus check` — say what would happen without touching the screen.
    static void Check()
    {
        var skip = Gate.SkipReason(Config.Load(), force: false).GetAwaiter().GetResult();
        Console.WriteLine(skip == null
            ? "вийшов би зараз — причин пропускати немає"
            : $"пропустив би — {skip.Reason}" + (skip.Retriable ? " (перечекав би)" : ""));
    }

    // `potyagus devices` — what the call check sees.
    static void Devices()
    {
        var mic = Mic.Users();
        var out_ = Speakers.ActiveSessions();
        Console.WriteLine("Мікрофон зараз тримають:");
        Console.WriteLine(mic.Count == 0 ? "  ⚪ нікого" : string.Join("\n", mic.Select(m => "  🔴 " + m)));
        Console.WriteLine("Звук зараз відтворюють:");
        Console.WriteLine(out_.Count == 0 ? "  ⚪ нікого" : string.Join("\n", out_.Distinct().Select(m => "  🔴 " + m)));
        Console.WriteLine();
        var cfg = Config.Load();
        Console.WriteLine(mic.Count > 0 && out_.Count == 0
            ? "→ схоже на голосовий набір, не дзвінок — Потягусь вийде"
            : Calls.InProgress(cfg).GetAwaiter().GetResult() ? "→ дзвінок — Потягусь почекає" : "→ дзвінка немає");
    }

    [DllImport("kernel32.dll")] static extern bool AttachConsole(int pid);
}
