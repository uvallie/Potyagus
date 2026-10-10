// The resident goose: tray icon, its own schedule, and one overlay session at a time.
// Mirrors the Controller class in src/main.swift step for step.

using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace Potyagus;

sealed class Agent : ApplicationContext
{
    readonly Library lib = Library.Load();
    readonly bool agentMode;
    readonly List<OverlayForm> forms = new();
    CoreWebView2Environment? env;

    Exercise current = null!;
    DateTime shownAt = DateTime.Now;
    /// Every display runs its own copy of the page, so the first answer wins
    /// and the rest are ignored — otherwise one stretch is logged once per monitor.
    bool handled;
    /// Minutes already spent waiting for a call to end.
    int waited;
    DateTime nextAt;

    readonly System.Windows.Forms.Timer clock = new() { Interval = 20_000 };
    System.Windows.Forms.Timer? watchdog, retry, snoozeTimer;
    NotifyIcon? tray;

    bool Showing => forms.Count > 0;

    public Agent(bool agentMode)
    {
        this.agentMode = agentMode;
        SessionLock.Start();
    }

    // MARK: one-shot (--now)

    public async void RunOnce(bool force)
    {
        await Attempt(force);
    }

    // MARK: resident agent

    public void StartAgent()
    {
        Autostart.Install();
        SetupTray();
        ScheduleNext();
        // Polling the wall clock instead of one long timer: survives sleep, clock changes, DST.
        clock.Tick += (_, _) => OnClock();
        clock.Start();
        SystemEvents.PowerModeChanged += (_, e) => { if (e.Mode == PowerModes.Resume) OnClock(); };
        Log.Write($"у треї, наступний вихід о {nextAt:HH\\:mm}");
    }

    /// Next slot of the schedule: every `intervalMinutes`, counted from midnight and shifted by `minute`.
    static DateTime NextSlot()
    {
        var c = Config.Load();
        var now = DateTime.Now;
        int step = c.IntervalMinutes, offset = c.Minute % step;
        var day = now.Date;
        var mins = (now - day).TotalMinutes;
        var k = Math.Max(0, (int)Math.Floor((mins - offset) / step) + 1);
        var t = day.AddMinutes(offset + k * step);
        return t.Date == now.Date ? t : day.AddDays(1).AddMinutes(offset);
    }

    void ScheduleNext() => nextAt = NextSlot();

    void OnClock()
    {
        if (DateTime.Now < nextAt) return;
        var fireAt = nextAt;
        ScheduleNext();
        // Woke from sleep long after the slot? Let this one go rather than nudge at 14:47.
        var late = DateTime.Now - fireAt;
        if (late.TotalMinutes > Math.Min(15, Config.Load().IntervalMinutes / 2))
        {
            Log.Write($"проспав вихід ({(int)late.TotalMinutes} хв) — пропускаю");
            return;
        }
        if (Showing) return;
        waited = 0;
        _ = Attempt(force: false);
    }

    /// A second launch (from the Start menu, say) while the goose is already resident.
    public void Reopened()
    {
        if (tray == null || tray.Visible) return;
        Config.Save("showMenuBarIcon", true);
        tray.Visible = true;
        tray.ShowBalloonTip(4000, "Потягусь знову в треї", "Іконка гуся повернулась — усе керування там.", ToolTipIcon.Info);
    }

    // MARK: tray menu

    void SetupTray()
    {
        tray = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = "Потягусь",
            ContextMenuStrip = new ContextMenuStrip(),
            Visible = Config.Load().ShowMenuBarIcon,
        };
        tray.ContextMenuStrip.Opening += (_, _) => RebuildMenu();
        tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)   // left click opens the menu too, like the Mac menu bar
                typeof(NotifyIcon).GetMethod("ShowContextMenu",
                    System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.Invoke(tray, null);
        };
        RebuildMenu();
    }

    void RebuildMenu()
    {
        var menu = tray!.ContextMenuStrip!;
        menu.Items.Clear();
        var cfg = Config.Load();

        menu.Items.Add(Disabled($"Сьогодні розім'ялась: {History.DoneToday()} / {cfg.Goal}"));
        menu.Items.Add(Disabled(Pause.Until() is DateTime until
            ? $"На паузі до {until:HH\\:mm}" : $"Наступний вихід о {nextAt:HH\\:mm}"));
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(Item("Потягнутись зараз", () => { if (!Showing) { waited = 0; _ = Attempt(force: true); } }));
        menu.Items.Add(new ToolStripSeparator());

        if (Pause.Until() != null)
            menu.Items.Add(Item("Зняти паузу", () => Pause.Set(null)));
        else
        {
            var pause = new ToolStripMenuItem("Пауза");
            foreach (var (title, mins) in new[] { ("30 хвилин", 30), ("1 година", 60), ("2 години", 120), ("До кінця дня", -1) })
                pause.DropDownItems.Add(Item(title, () => Pause.Set(Pause.UntilFor(mins))));
            menu.Items.Add(pause);
        }
        menu.Items.Add(new ToolStripSeparator());

        var catalog = new ToolStripMenuItem("Каталог вправ");
        foreach (var (title, items) in lib.Groups())
        {
            catalog.DropDownItems.Add(Disabled(title));
            foreach (var e in items)
            {
                var it = Item($"    {e.Name} · {e.Seconds} с", () => ToggleExercise(e.Id));
                it.Checked = !cfg.DisabledExercises.Contains(e.Id);
                catalog.DropDownItems.Add(it);
            }
        }
        menu.Items.Add(catalog);

        var freq = new ToolStripMenuItem("Частота");
        foreach (var (title, mins) in new[] { ("Кожні 30 хвилин", 30), ("Щогодини", 60), ("Кожні 90 хвилин", 90) })
        {
            var it = Item(title, () => { Config.Save("intervalMinutes", mins); ScheduleNext(); });
            it.Checked = cfg.IntervalMinutes == mins;
            freq.DropDownItems.Add(it);
        }
        menu.Items.Add(freq);

        var sound = new ToolStripMenuItem("Звук");
        foreach (var (title, vol) in new[] { ("Гучно", 100), ("Середньо", 50), ("Тихо", 20), ("Вимкнено", 0) })
        {
            var it = Item(title, () => Config.Save("volume", vol));
            it.Checked = cfg.Volume == vol;
            sound.DropDownItems.Add(it);
        }
        menu.Items.Add(sound);

        menu.Items.Add(Item("Приховати іконку з трею…", HideIcon));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(Item("Вимкнути автозапуск і вийти", Uninstall));
        menu.Items.Add(Item("Вийти", Quit));
    }

    static ToolStripMenuItem Item(string title, Action act)
    {
        var it = new ToolStripMenuItem(title);
        it.Click += (_, _) => act();
        return it;
    }
    static ToolStripMenuItem Disabled(string title) => new(title) { Enabled = false };

    /// Tick / untick an exercise in the catalogue. The last ticked one stays — the goose needs something to show.
    void ToggleExercise(string id)
    {
        var off = Config.Load().DisabledExercises.ToHashSet();
        if (off.Contains(id)) off.Remove(id);
        else if (lib.Exercises.Count(e => !off.Contains(e.Id)) > 1) off.Add(id);
        else { System.Media.SystemSounds.Beep.Play(); return; }
        Config.Save("disabledExercises", new JsonArray(lib.Exercises.Select(e => e.Id).Where(off.Contains)
                                                          .Select(s => (JsonNode)JsonValue.Create(s)!).ToArray()));
    }

    void HideIcon()
    {
        var ok = MessageBox.Show(
            "Нагадування працюватимуть далі. Щоб повернути іконку й меню — запусти Potyagus ще раз.",
            "Приховати іконку Потягуся?", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
        if (ok != DialogResult.OK) return;
        Config.Save("showMenuBarIcon", false);
        tray!.Visible = false;
    }

    void Uninstall()
    {
        var ok = MessageBox.Show(
            "Він більше не запускатиметься сам. Щоб повернути — просто запусти застосунок ще раз.",
            "Вимкнути Потягуся?", MessageBoxButtons.OKCancel, MessageBoxIcon.Question);
        if (ok != DialogResult.OK) return;
        Autostart.Remove();
        Quit();
    }

    void Quit()
    {
        if (tray != null) tray.Visible = false;
        TearDown();
        ExitThread();
    }

    // MARK: showing the goose

    /// Show the overlay, or wait out a reason that will pass by itself.
    async Task Attempt(bool force)
    {
        var cfg = Config.Load();
        var skip = await Gate.SkipReason(cfg, force);
        if (skip == null) { await Present(); return; }

        if (skip.Retriable && cfg.CallRetryMinutes > 0 && waited + cfg.CallRetryMinutes <= cfg.CallRetryWindowMinutes)
        {
            waited += cfg.CallRetryMinutes;
            Log.Write($"{skip.Reason} — перевірю ще раз через {cfg.CallRetryMinutes} хв");
            retry?.Dispose();
            retry = Once(cfg.CallRetryMinutes * 60_000, () => _ = Attempt(force: false));
            return;
        }

        var note = waited > 0 ? $"{skip.Reason}; чекав {waited} хв" : skip.Reason;
        Log.Write("пропускаю — " + note);
        History.Append(new() { ["ts"] = History.Now(), ["reason"] = "auto-skip", ["note"] = note });
        if (!agentMode) ExitThread();
    }

    /// Pick an exercise that hasn't shown up in the last few nudges.
    Exercise PickExercise()
    {
        var off = Config.Load().DisabledExercises.ToHashSet();
        var enabled = lib.Exercises.Where(e => !off.Contains(e.Id)).ToList();
        var pool = enabled.Count == 0 ? lib.Exercises : enabled;
        // With only a few ticked, "not in the last four" shrinks so there is still a choice.
        var recent = History.LastExerciseIds(Math.Min(4, pool.Count - 1)).ToHashSet();
        var fresh = pool.Where(e => !recent.Contains(e.Id)).ToList();
        var from = fresh.Count == 0 ? pool : fresh;
        return from[Random.Shared.Next(from.Count)];
    }

    async Task Present()
    {
        if (Showing) return;
        current = PickExercise();
        shownAt = DateTime.Now;
        handled = false;

        env ??= await CoreWebView2Environment.CreateAsync(null, Paths.WebViewData,
            // the goose honks on arrival, before anyone has clicked anything
            new CoreWebView2EnvironmentOptions("--autoplay-policy=no-user-gesture-required"));

        var screens = Screen.AllScreens;
        if (screens.Length == 0) { if (!agentMode) ExitThread(); return; }
        // The display the pointer is on — a far better guess at "where she is looking".
        var active = Screen.FromPoint(Cursor.Position);
        var cfg = Config.Load();

        // Every display gets the full overlay, so it never lands on the wrong monitor.
        foreach (var screen in screens)
        {
            var primary = screen.DeviceName == active.DeviceName;
            var form = new OverlayForm(screen, primary, Payload(cfg, muted: !primary));
            form.Message += OnMessage;
            forms.Add(form);
            Log.Write($"екран {screen.DeviceName} {screen.Bounds}" + (primary ? " [активний]" : ""));
        }
        foreach (var form in forms) form.ShowOverlay();
        try
        {
            await Task.WhenAll(forms.Select(f => f.LoadAsync(env)));
        }
        catch (Exception e)
        {
            Log.Write("webview: " + e);
            handled = true;
            Close("error");
            return;
        }
        // the primary screen last, so it ends up with the focus
        forms.FirstOrDefault(f => f.Primary)?.ShowOverlay();
        ArmWatchdog();
    }

    string Payload(Config cfg, bool muted)
    {
        var payload = new Dictionary<string, object?>
        {
            ["taunt"]      = lib.Taunts.Count > 0 ? lib.Taunts[Random.Shared.Next(lib.Taunts.Count)] : "Встань і розімнись.",
            ["doneLine"]   = lib.DoneLines.Count > 0 ? lib.DoneLines[Random.Shared.Next(lib.DoneLines.Count)] : "Молодець.",
            ["name"]       = current.Name,
            ["pose"]       = current.Pose,
            ["seconds"]    = current.Seconds,
            ["steps"]      = current.Steps,
            ["todayCount"] = History.DoneToday(),
            ["goal"]       = cfg.Goal,
            ["volume"]     = cfg.Volume / 100.0,
            ["interval"]   = cfg.IntervalMinutes,
            ["muted"]      = muted,
        };
        return JsonSerializer.Serialize(payload, Json.Compact);
    }

    /// If it is simply ignored, step aside rather than sit there forever.
    void ArmWatchdog()
    {
        watchdog?.Dispose();
        watchdog = Once((current.Seconds + 240) * 1000, () =>
        {
            if (handled) return;
            handled = true;
            Close("ignored");
        });
    }

    // MARK: messages from the page

    void OnMessage(OverlayForm _, JsonObject body)
    {
        if (body["action"] is not JsonValue av || !av.TryGetValue<string>(out var action)) return;
        if (handled) return;
        handled = true;
        switch (action)
        {
            case "dnd":
                // «Не турбувати»: the same pause as in the tray menu, straight from the overlay.
                var mins = body["minutes"] is JsonValue mv && mv.TryGetValue<double>(out var m) ? (int)m : 60;
                Pause.Set(Pause.UntilFor(mins));
                Close("dnd");
                break;
            case "done": case "skip": case "ignored":
                Close(action);
                break;
            case "snooze":
                Snooze();
                break;
            default:
                handled = false;
                break;
        }
    }

    void LogResult(string reason) => History.Append(new()
    {
        ["ts"] = History.Now(),
        ["reason"] = reason,
        ["exercise"] = current.Id,
        ["name"] = current.Name,
        ["seconds"] = current.Seconds,
        ["shownFor"] = (int)(DateTime.Now - shownAt).TotalSeconds,
    });

    void Close(string reason)
    {
        watchdog?.Dispose();
        LogResult(reason);
        TearDown();
        if (!agentMode) ExitThread();
    }

    void Snooze()
    {
        watchdog?.Dispose();
        LogResult("snooze");
        TearDown();
        snoozeTimer?.Dispose();
        snoozeTimer = Once(300_000, () => _ = Present());
    }

    void TearDown()
    {
        foreach (var f in forms) f.CloseForGood();
        forms.Clear();
    }

    static System.Windows.Forms.Timer Once(int ms, Action act)
    {
        var t = new System.Windows.Forms.Timer { Interval = Math.Max(1, ms) };
        t.Tick += (_, _) => { t.Stop(); act(); };
        t.Start();
        return t;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { tray?.Dispose(); clock.Dispose(); }
        base.Dispose(disposing);
    }
}

/// Start at login: HKCU\…\Run, the per-user equivalent of the Mac launch agent.
static class Autostart
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "Potyagus";

    public static void Install()
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            var cmd = $"\"{Environment.ProcessPath}\"";
            if (k.GetValue(Name) as string != cmd) k.SetValue(Name, cmd);
        }
        catch (Exception e) { Log.Write("autostart: " + e.Message); }
    }

    public static void Remove()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            k?.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch (Exception e) { Log.Write("autostart: " + e.Message); }
    }
}
