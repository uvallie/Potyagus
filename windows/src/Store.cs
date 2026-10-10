// Config, exercise library and history: the same files and keys as the Mac app (src/main.swift),
// just under %APPDATA%\Potyagus instead of ~/Library/Application Support/Potyagus.

using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Potyagus;

static class Paths
{
    public static readonly string Support = Init();
    static string Init()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Potyagus");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static string History => Path.Combine(Support, "history.jsonl");
    public static string Config  => Path.Combine(Support, "config.json");
    public static string Pause   => Path.Combine(Support, "paused-until");
    public static string Log     => Path.Combine(Support, "agent.log");

    /// Next to Potyagus.exe: web\overlay.html, web\clips, web\sfx, exercises.json.
    public static string AppDir  => AppContext.BaseDirectory;
    public static string Web     => Path.Combine(AppDir, "web");

    /// WebView2 keeps its profile here (cache, autoplay state) — not in the roaming folder.
    public static string WebViewData => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Potyagus", "WebView2");
}

static class Log
{
    public static void Write(string line)
    {
        var text = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}";
        System.Diagnostics.Debug.WriteLine(text);
        try { File.AppendAllText(Paths.Log, text + Environment.NewLine); } catch { }
    }
}

static class Json
{
    public static readonly JsonSerializerOptions Pretty = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,   // keep Cyrillic readable
    };
    public static readonly JsonSerializerOptions Compact = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };
}

// MARK: - Config

sealed class Config
{
    public int StartHour = 9;
    public int EndHour = 21;
    /// Minute past the hour to show up. Not :00 — that's when meetings start; by :05 a call
    /// has already grabbed the microphone and the call check can see it.
    public int Minute = 5;
    public bool WeekdaysOnly = false;
    public int Goal = 8;
    /// On Windows these are process names (as in Task Manager → Details, without ".exe").
    public List<string> BlockApps = new() { "Zoom", "ms-teams", "Teams", "Discord", "CiscoCollabHost", "webexmta" };
    /// Stay out of the way while the microphone is live — covers Zoom, Meet, Teams,
    /// Slack huddles and anything else, browser-based calls included.
    public bool SkipDuringCalls = true;
    public int CallRetryMinutes = 5;
    public int CallRetryWindowMinutes = 45;
    /// Require sound output too, so dictation isn't mistaken for a call.
    public bool RequireOutputForCall = true;
    /// Seconds to wait before re-sampling; dictation bursts end, calls don't.
    public int ConfirmCallSeconds = 8;
    /// Minutes between nudges. 60 = every hour at `Minute`; other values count from midnight,
    /// shifted by `Minute` (30 → :05 and :35).
    public int IntervalMinutes = 60;
    /// Goose voice and chimes, 0–100. 0 is silent; the nudge itself still shows up.
    public int Volume = 100;
    public bool ShowMenuBarIcon = true;
    public List<string> DisabledExercises = new();

    public static Config Load()
    {
        var c = new Config();
        JsonObject? j = ReadRaw();
        if (j == null) return c;

        if (Int(j, "startHour") is int sh) c.StartHour = sh;
        if (Int(j, "endHour") is int eh) c.EndHour = eh;
        if (Int(j, "minute") is int m && m is >= 0 and <= 59) c.Minute = m;
        if (Bool(j, "weekdaysOnly") is bool wd) c.WeekdaysOnly = wd;
        if (Int(j, "goal") is int g) c.Goal = g;
        if (Strings(j, "blockApps") is { } ba) c.BlockApps = ba;
        if (Bool(j, "skipDuringCalls") is bool sc) c.SkipDuringCalls = sc;
        if (Int(j, "callRetryMinutes") is int cr) c.CallRetryMinutes = cr;
        if (Int(j, "callRetryWindowMinutes") is int cw) c.CallRetryWindowMinutes = cw;
        if (Bool(j, "requireOutputForCall") is bool ro) c.RequireOutputForCall = ro;
        if (Int(j, "confirmCallSeconds") is int cs) c.ConfirmCallSeconds = cs;
        if (Int(j, "intervalMinutes") is int im && im is >= 10 and <= 480) c.IntervalMinutes = im;
        if (Int(j, "volume") is int v) c.Volume = Math.Clamp(v, 0, 100);
        if (Bool(j, "showMenuBarIcon") is bool si) c.ShowMenuBarIcon = si;
        if (Strings(j, "disabledExercises") is { } de) c.DisabledExercises = de;
        return c;
    }

    static JsonObject? ReadRaw()
    {
        try { return JsonNode.Parse(File.ReadAllText(Paths.Config)) as JsonObject; }
        catch { return null; }
    }

    /// Change one key in config.json, leaving everything else the user wrote there alone.
    public static void Save(string key, JsonNode? value)
    {
        var j = ReadRaw() ?? new JsonObject();
        j[key] = value;
        var sorted = new JsonObject();
        foreach (var kv in j.OrderBy(kv => kv.Key, StringComparer.Ordinal).ToList())
        {
            j.Remove(kv.Key);
            sorted[kv.Key] = kv.Value;
        }
        try { File.WriteAllText(Paths.Config, sorted.ToJsonString(Json.Pretty)); } catch { }
    }

    static int? Int(JsonObject j, string k) =>
        j[k] is JsonValue v && v.TryGetValue<double>(out var d) ? (int)d : null;
    static bool? Bool(JsonObject j, string k) =>
        j[k] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;
    static List<string>? Strings(JsonObject j, string k) =>
        j[k] is JsonArray a ? a.OfType<JsonValue>().Select(x => x.TryGetValue<string>(out var s) ? s : null)
                                .Where(s => s != null).Select(s => s!).ToList()
                            : null;
}

// MARK: - Exercise data

sealed class Exercise
{
    [JsonPropertyName("id")]      public string Id { get; set; } = "";
    [JsonPropertyName("pose")]    public string Pose { get; set; } = "";
    [JsonPropertyName("seconds")] public int Seconds { get; set; }
    [JsonPropertyName("name")]    public string Name { get; set; } = "";
    [JsonPropertyName("steps")]   public List<string> Steps { get; set; } = new();
    /// Catalogue section («Шия», «Очі»…). Optional so custom exercises.json files keep working.
    [JsonPropertyName("group")]   public string? Group { get; set; }
}

sealed class Library
{
    [JsonPropertyName("exercises")]  public List<Exercise> Exercises { get; set; } = new();
    [JsonPropertyName("taunts")]     public List<string> Taunts { get; set; } = new();
    [JsonPropertyName("done_lines")] public List<string> DoneLines { get; set; } = new();

    public static Library Load()
    {
        var path = Path.Combine(Paths.AppDir, "exercises.json");
        var lib = JsonSerializer.Deserialize<Library>(File.ReadAllText(path));
        if (lib == null || lib.Exercises.Count == 0) throw new InvalidDataException("exercises.json is empty");
        return lib;
    }

    /// Exercises in catalogue order: sections as they first appear in the file.
    public IEnumerable<(string Title, List<Exercise> Items)> Groups() =>
        Exercises.GroupBy(e => e.Group ?? "Інше").Select(g => (g.Key, g.ToList()));
}

// MARK: - History

static class History
{
    public static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public static void Append(Dictionary<string, object?> entry)
    {
        try { File.AppendAllText(Paths.History, JsonSerializer.Serialize(entry, Json.Compact) + "\n"); }
        catch (Exception e) { Log.Write("history: " + e.Message); }
    }

    public static List<JsonObject> Lines()
    {
        if (!File.Exists(Paths.History)) return new();
        var rows = new List<JsonObject>();
        foreach (var line in File.ReadLines(Paths.History))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try { if (JsonNode.Parse(line) is JsonObject o) rows.Add(o); } catch { }
        }
        return rows;
    }

    public static int DoneToday()
    {
        var today = DateTime.Now.Date;
        return Lines().Count(r =>
            r["reason"] is JsonValue rv && rv.TryGetValue<string>(out var reason) && reason == "done"
            && r["ts"] is JsonValue ts && ts.TryGetValue<double>(out var t)
            && DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000)).LocalDateTime.Date == today);
    }

    public static List<string> LastExerciseIds(int n) =>
        n <= 0 ? new()
               : Lines().TakeLast(n)
                        .Select(r => r["exercise"] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null)
                        .Where(s => s != null).Select(s => s!).ToList();
}

// MARK: - Pause

static class Pause
{
    public static DateTime? Until()
    {
        try
        {
            var s = File.ReadAllText(Paths.Pause).Trim();
            if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var t)) return null;
            var d = DateTimeOffset.FromUnixTimeMilliseconds((long)(t * 1000)).LocalDateTime;
            return d > DateTime.Now ? d : null;
        }
        catch { return null; }
    }

    public static void Set(DateTime? until)
    {
        try
        {
            if (until is DateTime d)
            {
                var t = new DateTimeOffset(d).ToUnixTimeMilliseconds() / 1000.0;
                File.WriteAllText(Paths.Pause, t.ToString(CultureInfo.InvariantCulture));
            }
            else if (File.Exists(Paths.Pause)) File.Delete(Paths.Pause);
        }
        catch { }
    }

    /// minutes < 0 → until the end of today, as in the Mac menu.
    public static DateTime UntilFor(int minutes) =>
        minutes < 0 ? DateTime.Now.Date.AddDays(1) : DateTime.Now.AddMinutes(minutes);
}
