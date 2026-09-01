// Розімнись — a drawn character that blocks the screen until you stretch.
// Builds into Розімнись.app; launchd wakes it every hour.

import Cocoa
import WebKit
import CoreGraphics
import CoreAudio

// MARK: - Paths

let support: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Potyagus", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

let historyURL = support.appendingPathComponent("history.jsonl")
let stateURL   = support.appendingPathComponent("state.json")
let configURL  = support.appendingPathComponent("config.json")
let pauseURL   = support.appendingPathComponent("paused-until")

// MARK: - Config

struct Config {
    var startHour  = 9
    var endHour    = 21
    var weekdaysOnly = false
    var goal       = 8
    var blockApps: [String] = ["us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime",
                               "com.hnc.Discord", "com.apple.QuickTimePlayerX"]
    /// Stay out of the way while the microphone is live — covers Zoom, Meet, Teams,
    /// Slack huddles and anything else, browser-based calls included.
    var skipDuringCalls = true
    /// How often to look again while a call is in progress, and for how long.
    var callRetryMinutes = 5
    var callRetryWindowMinutes = 45
    /// Require the speakers to be live too, so dictation isn't mistaken for a call.
    var requireOutputForCall = true
    /// Seconds to wait before re-sampling; dictation bursts end, calls don't.
    var confirmCallSeconds = 8

    static func load() -> Config {
        var c = Config()
        guard let d = try? Data(contentsOf: configURL),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
        if let v = j["startHour"]    as? Int      { c.startHour = v }
        if let v = j["endHour"]      as? Int      { c.endHour = v }
        if let v = j["weekdaysOnly"] as? Bool     { c.weekdaysOnly = v }
        if let v = j["goal"]         as? Int      { c.goal = v }
        if let v = j["blockApps"]    as? [String] { c.blockApps = v }
        if let v = j["skipDuringCalls"]        as? Bool { c.skipDuringCalls = v }
        if let v = j["callRetryMinutes"]       as? Int  { c.callRetryMinutes = v }
        if let v = j["callRetryWindowMinutes"] as? Int  { c.callRetryWindowMinutes = v }
        if let v = j["requireOutputForCall"]   as? Bool { c.requireOutputForCall = v }
        if let v = j["confirmCallSeconds"]     as? Int  { c.confirmCallSeconds = v }
        return c
    }
}

// MARK: - Exercise data

struct Exercise: Decodable {
    let id: String, pose: String, seconds: Int, name: String, steps: [String]
}
struct Library: Decodable {
    let exercises: [Exercise], taunts: [String], done_lines: [String]
}

func loadLibrary() -> Library {
    let candidates: [URL?] = [
        Bundle.main.url(forResource: "exercises", withExtension: "json"),
        URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()          // .../MacOS
            .deletingLastPathComponent()          // .../Contents
            .appendingPathComponent("Resources/exercises.json")
    ]
    for case let url? in candidates {
        if let d = try? Data(contentsOf: url), let lib = try? JSONDecoder().decode(Library.self, from: d) {
            return lib
        }
    }
    fputs("rozimnys: exercises.json not found\n", stderr)
    exit(2)
}

func overlayURL() -> URL {
    if let u = Bundle.main.url(forResource: "overlay", withExtension: "html") { return u }
    return URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/overlay.html")
}

// MARK: - History

func appendHistory(_ entry: [String: Any]) {
    guard let line = try? JSONSerialization.data(withJSONObject: entry),
          var text = String(data: line, encoding: .utf8) else { return }
    text += "\n"
    if let h = try? FileHandle(forWritingTo: historyURL) {
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
    } else {
        try? text.write(to: historyURL, atomically: true, encoding: .utf8)
    }
}

func historyLines() -> [[String: Any]] {
    guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap {
        guard let d = $0.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

func doneToday() -> Int {
    let cal = Calendar.current
    return historyLines().filter { row in
        guard (row["reason"] as? String) == "done", let ts = row["ts"] as? Double else { return false }
        return cal.isDateInToday(Date(timeIntervalSince1970: ts))
    }.count
}

func lastExerciseIDs(_ n: Int) -> [String] {
    Array(historyLines().suffix(n).compactMap { $0["exercise"] as? String })
}

// MARK: - Should we nudge at all?

func screenIsLocked() -> Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = info["CGSSessionScreenIsLocked"] as? Int, locked == 1 { return true }
    if let onConsole = info["kCGSSessionOnConsoleKey"] as? Bool, !onConsole { return true }
    return false
}

func pausedUntil() -> Date? {
    guard let s = try? String(contentsOf: pauseURL, encoding: .utf8),
          let t = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    let d = Date(timeIntervalSince1970: t)
    return d > Date() ? d : nil
}

/// True when any audio input device is currently capturing.
///
/// This is the one signal that works for every call app: Zoom and Teams are native,
/// Google Meet is just a browser tab with no bundle id of its own, but all of them
/// hold the microphone open. Muting inside the app doesn't release the device, so a
/// muted participant still counts as "on a call". Reading CoreAudio properties needs
/// no permission and never prompts.
struct AudioInput {
    let name: String
    let channels: Int
    let running: Bool
}

/// Every audio device that has input channels, with whether it is currently capturing.
func audioDevices(scope: AudioObjectPropertyScope) -> [AudioInput] {
    var result: [AudioInput] = []
    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size) == noErr,
          size > 0 else { return result }

    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddr, 0, nil, &size, &devices) == noErr
    else { return result }

    for dev in devices {
        // Skip devices with no channels in this direction.
        var cfgAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var cfgSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &cfgAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &cfgAddr, 0, nil, &cfgSize, raw) == noErr else { continue }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { continue }

        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &runAddr, 0, nil, &runSize, &running) == noErr else { continue }

        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let name = AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, &cfName) == noErr
            ? (cfName as String) : "пристрій \(dev)"

        result.append(AudioInput(name: name, channels: channels, running: running != 0))
    }
    return result
}

func micInUse() -> Bool    { audioDevices(scope: kAudioObjectPropertyScopeInput).contains  { $0.running } }
func speakerInUse() -> Bool { audioDevices(scope: kAudioObjectPropertyScopeOutput).contains { $0.running } }

/// Tell a call apart from dictation.
///
/// Dictation and voice typing hold the microphone too, so "mic is live" alone is not
/// enough. On a call you are also *listening*, so the output device is running as well;
/// while dictating, only the input is. We also sample twice a few seconds apart, because
/// dictation comes in short bursts while a call stays open.
func callInProgress(_ cfg: Config) -> Bool {
    guard cfg.skipDuringCalls, micInUse() else { return false }
    if cfg.requireOutputForCall && !speakerInUse() { return false }   // mic only → dictation

    guard cfg.confirmCallSeconds > 0 else { return true }
    Thread.sleep(forTimeInterval: Double(cfg.confirmCallSeconds))
    guard micInUse() else { return false }
    return !cfg.requireOutputForCall || speakerInUse()
}

func blockedByFrontApp(_ cfg: Config) -> String? {
    guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
    return cfg.blockApps.contains(front) ? front : nil
}

/// Why we should not show the overlay right now.
/// `retriable` marks the reasons that pass on their own — worth waiting out
/// rather than writing off the whole hour.
struct Skip {
    let reason: String
    let retriable: Bool
}

func skipReason(_ cfg: Config, force: Bool) -> Skip? {
    if force { return nil }
    if let until = pausedUntil() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return Skip(reason: "на паузі до \(f.string(from: until))", retriable: false)
    }
    if screenIsLocked() { return Skip(reason: "екран заблоковано", retriable: false) }
    let now = Calendar.current.dateComponents([.hour, .weekday], from: Date())
    if let h = now.hour, h < cfg.startHour || h >= cfg.endHour {
        return Skip(reason: "поза робочими годинами (\(cfg.startHour):00–\(cfg.endHour):00)", retriable: false)
    }
    if cfg.weekdaysOnly, let wd = now.weekday, wd == 1 || wd == 7 {
        return Skip(reason: "вихідний", retriable: false)
    }
    if callInProgress(cfg) {
        return Skip(reason: "іде дзвінок", retriable: true)
    }
    if let app = blockedByFrontApp(cfg) {
        return Skip(reason: "активний застосунок у блоклисті (\(app))", retriable: true)
    }
    return nil
}

// MARK: - Window

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - App

final class Controller: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {

    let cfg = Config.load()
    let lib = loadLibrary()
    var windows: [OverlayWindow] = []
    var webViews: [WKWebView] = []
    var primaryWebView: WKWebView?
    var current: Exercise!
    var shownAt = Date()
    var watchdog: Timer?
    /// Every display runs its own copy of the page, so the first answer wins
    /// and the rest are ignored — otherwise one stretch is logged once per monitor.
    var handled = false
    let force = CommandLine.arguments.contains("--force") || CommandLine.arguments.contains("--now")
    /// Minutes already spent waiting for a call to end.
    var waited = 0
    var retryTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // `rozimnys check` — say what would happen without touching the screen.
        if CommandLine.arguments.contains("--devices") {
            let cfg = self.cfg
            let ins  = audioDevices(scope: kAudioObjectPropertyScopeInput)
            let outs = audioDevices(scope: kAudioObjectPropertyScopeOutput)
            if ins.isEmpty {
                print("Аудіовходів не знайдено — детекція дзвінка не працюватиме.")
            }
            print("Мікрофони:")
            for i in ins  { print("  \(i.running ? "🔴 активний" : "⚪️ вільний  ")  \(i.name)") }
            print("Динаміки:")
            for o in outs { print("  \(o.running ? "🔴 активний" : "⚪️ вільний  ")  \(o.name)") }
            print("")
            print("мікрофон: \(micInUse() ? "зайнятий" : "вільний"), вихід: \(speakerInUse() ? "активний" : "тихо")")
            print(micInUse() && !speakerInUse()
                  ? "→ схоже на голосовий набір, не дзвінок — Потягусь вийде"
                  : (callInProgress(cfg) ? "→ дзвінок — Потягусь почекає" : "→ дзвінка немає"))
            NSApp.terminate(nil); return
        }

        if CommandLine.arguments.contains("--check") {
            if let skip = skipReason(cfg, force: false) {
                print("пропустив би — \(skip.reason)" + (skip.retriable ? " (перечекав би)" : ""))
            } else {
                print("вийшов би зараз — причин пропускати немає")
            }
            NSApp.terminate(nil); return
        }

        // A retry loop can still be waiting when the next hour fires; don't stack up.
        let id = Bundle.main.bundleIdentifier ?? "com.alina.potyagus"
        let mine = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != mine }) {
            fputs("Розімнись: вже запущений — виходжу\n", stderr)
            NSApp.terminate(nil); return
        }

        attempt()
    }

    /// Show the overlay, or wait out a reason that will pass by itself.
    func attempt() {
        guard let skip = skipReason(cfg, force: force) else { present(); return }

        if skip.retriable, cfg.callRetryMinutes > 0, waited + cfg.callRetryMinutes <= cfg.callRetryWindowMinutes {
            waited += cfg.callRetryMinutes
            fputs("Розімнись: \(skip.reason) — перевірю ще раз через \(cfg.callRetryMinutes) хв\n", stderr)
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: Double(cfg.callRetryMinutes) * 60,
                                              repeats: false) { [weak self] _ in self?.attempt() }
            return
        }

        let note = waited > 0 ? "\(skip.reason); чекав \(waited) хв" : skip.reason
        fputs("Розімнись: пропускаю — \(note)\n", stderr)
        appendHistory(["ts": Date().timeIntervalSince1970, "reason": "auto-skip", "note": note])
        NSApp.terminate(nil)
    }

    // Pick an exercise that hasn't shown up in the last few nudges.
    func pickExercise() -> Exercise {
        let recent = Set(lastExerciseIDs(4))
        let fresh = lib.exercises.filter { !recent.contains($0.id) }
        return (fresh.isEmpty ? lib.exercises : fresh).randomElement()!
    }

    func present() {
        current = pickExercise()
        shownAt = Date()
        handled = false

        let cc = WKUserContentController()
        cc.add(self, name: "rozimnys")
        let conf = WKWebViewConfiguration()
        conf.userContentController = cc
        conf.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 10.15, *) { conf.defaultWebpagePreferences.allowsContentJavaScript = true }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { NSApp.terminate(nil); return }
        let active = activeScreen()
        let url = overlayURL()

        // Every display gets the full overlay, so it never lands on the wrong monitor.
        for screen in screens {
            let wv = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: conf)
            wv.navigationDelegate = self
            wv.setValue(false, forKey: "drawsBackground")
            if wv.responds(to: Selector(("setInspectable:"))) { wv.setValue(true, forKey: "inspectable") }

            let win = makeWindow(on: screen)
            win.contentView = wv
            windows.append(win)
            webViews.append(wv)
            if screen == active { primaryWebView = wv }

            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

            fputs("Розімнись: екран \(NSStringFromRect(screen.frame)) → вікно \(NSStringFromRect(win.frame))"
                  + (screen == active ? " [активний]" : "") + "\n", stderr)
        }
        if primaryWebView == nil { primaryWebView = webViews.first }

        NSApp.activate(ignoringOtherApps: true)
        for w in windows {
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.42
                w.animator().alphaValue = 1
            }
        }
        NSSound(named: "Blow")?.play()

        // If it is simply ignored, step aside rather than sit there forever.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: Double(current.seconds) + 240, repeats: false) { [weak self] _ in
            guard let self, !self.handled else { return }
            self.handled = true
            self.close(reason: "ignored")
        }
    }

    /// The display the pointer is on — a far better guess at "where she is looking"
    /// than NSScreen.main, which is meaningless for a background agent with no key window.
    func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    func makeWindow(on screen: NSScreen) -> OverlayWindow {
        // contentRect is in global screen coordinates; passing `screen:` too would offset it again.
        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        w.setFrame(screen.frame, display: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = false
        return w
    }

    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {
        let payload: [String: Any] = [
            "taunt":      lib.taunts.randomElement() ?? "Встань і розімнись.",
            "doneLine":   lib.done_lines.randomElement() ?? "Молодець.",
            "name":       current.name,
            "pose":       current.pose,
            "seconds":    current.seconds,
            "steps":      current.steps,
            "todayCount": doneToday(),
            "goal":       cfg.goal,
            "muted":      wv !== primaryWebView
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: d, encoding: .utf8) else { return }
        wv.evaluateJavaScript("window.rozimnysInit(\(json))", completionHandler: nil)
    }

    // MARK: messages from the page

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let body = msg.body as? [String: Any],
              let action = body["action"] as? String else { return }
        guard !handled else { return }
        handled = true
        switch action {
        case "done", "skip", "ignored": close(reason: action)
        case "snooze":                  snooze()
        default: break
        }
    }

    func log(_ reason: String) {
        appendHistory([
            "ts": Date().timeIntervalSince1970,
            "reason": reason,
            "exercise": current.id,
            "name": current.name,
            "seconds": current.seconds,
            "shownFor": Int(Date().timeIntervalSince(shownAt))
        ])
    }

    func close(reason: String) {
        watchdog?.invalidate()
        log(reason)
        fadeOutAndQuit()
    }

    func snooze() {
        watchdog?.invalidate()
        log("snooze")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            for w in self.windows { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in self.windows { w.orderOut(nil) }
            self.windows.removeAll()
            self.webViews.removeAll()
            self.primaryWebView = nil
            Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { _ in self.present() }
        })
    }

    func fadeOutAndQuit() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            for w in self.windows { w.animator().alphaValue = 0 }
        }, completionHandler: { NSApp.terminate(nil) })
    }
}

// MARK: - Boot

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
