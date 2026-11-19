import AppKit
import ServiceManagement
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { return selftest() }
        if let i = args.firstIndex(of: "--cover"), i + 1 < args.count { return cover(matches: Array(args[(i + 1)...])) }
        if let i = args.firstIndex(of: "--drill"), i + 2 < args.count, let seconds = Double(args[i + 1]) {
            return drill(seconds: seconds, matches: Array(args[(i + 2)...]))
        }
        if let mode = ["--window", "--picker", "--bench"].first(where: args.contains) { return demoWindow(mode) }
        // --proxy <port> [interface]: only the tunnel proxy, for tests. An interface name replaces the VPN tunnel.
        if let i = args.firstIndex(of: "--proxy"), i + 1 < args.count, let port = UInt16(args[i + 1]) {
            TunnelProxy.shared.start(port: port, interface: i + 2 < args.count ? args[i + 2] : nil)
            dispatchMain()
        }
        // --gate <port> <dns port> [interface]: only the gate (DNS answerer + forwarder), for tests.
        if let i = args.firstIndex(of: "--gate"), i + 2 < args.count, let port = UInt16(args[i + 1]), let dnsPort = UInt16(args[i + 2]) {
            if i + 3 < args.count { Tunnel.shared.pinned = args[i + 3] }
            Gate.shared.start(port: port, dnsPort: dnsPort)
            dispatchMain()
        }
        // --update <app> [feed]: bring that copy of the app up to the latest release, in the open (tests).
        if let i = args.firstIndex(of: "--update"), i + 1 < args.count {
            exit(Updater.once(bundle: URL(fileURLWithPath: args[i + 1]), feed: i + 2 < args.count ? args[i + 2] : Updater.feed))
        }
        // --through <app>: start the app through the tunnel proxy, exactly as the button in the window does (tests).
        if let i = args.firstIndex(of: "--through"), i + 1 < args.count {
            Gate.shared.open(args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
            CFRunLoopRun()
        }
        onlyOne()
        ZaslonApp.main()
    }

    /// One tray instance at a time, through a lock file. The copy started by the system's launch agent is the one
    /// that gets restarted after a crash, so it wins: it asks an older copy to quit and waits for the lock. Any
    /// other second copy just leaves.
    static func onlyOne() {
        let folder = NSHomeDirectory() + "/Library/Application Support/Zaslon"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lock = open(folder + "/lock", O_RDWR | O_CREAT, 0o600)
        guard lock >= 0 else { return }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard managed else { exit(0) }
            var text = [CChar](repeating: 0, count: 32)
            pread(lock, &text, 31, 0)
            if let holder = pid_t(String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)), holder > 1 { kill(holder, SIGTERM) }
            flock(lock, LOCK_EX) // returns once the older copy is gone
        }
        ftruncate(lock, 0)
        let me = "\(getpid())\n"
        pwrite(lock, me, me.utf8.count, 0)
        // The descriptor stays open for the life of the process: that is what holds the lock.
    }
}

let agentLabel = "local.zaslon.agent"
/// True when the system's launch agent started this copy, which is the one it restarts after a crash.
let managed = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel

/// Opens this app again a second from now, from a process in its own session so that it outlives this one.
func relaunchSoon() {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    let words = ["/bin/sh", "-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    var argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
    var pid = pid_t()
    posix_spawn(&pid, "/bin/sh", nil, &attributes, &argv, environ)
    posix_spawnattr_destroy(&attributes)
}

/// Debug: the real panel in an ordinary window that stays open. Touches no process and never takes focus.
/// `--window` just shows it; `--bench` also opens the picker, scrolls it and types into the search, then prints every main-thread stall;
/// `--picker` shows it with the picker open and scrolled a little. With SHOT=<png> any of them saves a picture and quits.
@MainActor func demoWindow(_ mode: String) {
    let bench = mode == "--bench"
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if bench { watchStalls() }
    let catalog = Catalog.shared
    catalog.refresh()
    if let ui = ProcessInfo.processInfo.environment["UI"] { Lang.shared.code = ui } // UI=en|ru: the language of the test window, not saved
    let g = Guard(live: false)
    g.signal = { _, _ in }
    g.update(true)
    let content = NSHostingController(rootView: Panel(g: g))
    // For a picture the window must look the same on every run, so it never becomes the active one.
    let window = ProcessInfo.processInfo.environment["SHOT"] != nil ? Still(contentViewController: content) : NSWindow(contentViewController: content)
    window.styleMask = [.titled, .closable]
    window.title = t("Zaslon (проверка)", "Zaslon (test)")
    // On the sharpest screen there is: a picture taken on an ordinary external monitor comes out at half the size.
    let sharp = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 860)
    window.setFrameTopLeftPoint(NSPoint(x: sharp.minX + 60, y: sharp.maxY - 60))
    window.orderFrontRegardless()
    // Placed again once the content has given the window its size: until then the system keeps it on the main screen.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { window.setFrameTopLeftPoint(NSPoint(x: sharp.minX + 60, y: sharp.maxY - 60)) }
    func scrollView(in view: NSView) -> NSScrollView? { view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView).first }
    let scroll = { (y: CGFloat) in
        guard let list = scrollView(in: window.contentView!) else { return }
        list.contentView.scroll(to: NSPoint(x: 0, y: y))
        list.reflectScrolledClipView(list.contentView)
    }
    // The capture call is hidden from Swift in new SDKs, so it is looked up by name; a process may capture its
    // own window without the screen-recording permission.
    do {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"), to: Capture.self)
        let picture = { capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 3)?.takeRetainedValue() }
        let save = { (image: CGImage, path: String) in
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        let after = { (seconds: Double, work: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
        let env = ProcessInfo.processInfo.environment
        // What to show: LOOK=light|dark, DROP=1 (WARP is down), OFF=1 (protection switched off), HOVER=1 (every
        // button as under the mouse), TAP=<seconds> (switch off and on, picture that long after the switch-on).
        if let look = env["LOOK"] { window.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua) }
        if env["DROP"] != nil { g.update(false) }
        if env["OFF"] != nil { g.enabled = false }
        // The settings picture shows updates switched on and up to date, whatever this Mac's own setting is.
        if env["GEAR"] != nil { (Updater.shared.on, Updater.shared.latest) = (true, true) }
        if env["LOG"] != nil { // the journal with a fixed evening of outages, in memory only
            let day = Calendar.current.startOfDay(for: Date())
            func outage(_ from: Double, _ to: Double, _ frozen: [String], _ refused: Int) -> Outage {
                Outage(start: day + from, end: day + to, frozen: frozen, refused: refused)
            }
            Journal.shared.outages = [
                outage(71378, 71406, ["Claude", "ChatGPT"], 3), outage(69363, 69391, ["Claude", "ChatGPT"], 5),
                outage(68594, 68757, ["ChatGPT"], 0), outage(68481, 68497, ["ChatGPT"], 0),
            ]
        }
        if env["TAP"] != nil { // switch off, then on, as two clicks on the shield would
            after(2.0) { withAnimation(.snappy(duration: 0.3)) { g.enabled = false } }
            after(2.6) { withAnimation(.snappy(duration: 0.3)) { g.enabled = true } }
        }
        Chip.showHover = env["HOVER"] != nil
        Gate.shared.ruled = Set(Gate.services.map(\.app)) // the test window shows the normal state, not this Mac's facts of the moment
        if mode == "--picker" {
            catalog.picking = true
            after(1.5) { scroll(400) }
        }
        // SHOT=<png> saves a picture of this window and quits.
        if let shot = env["SHOT"] {
            after(2.2) { scroll(420) } // the bar shows only for a moment after a scroll
            // IDLE=1 waits until an idle bar should have faded out; TAP=1 shoots while the ring is on its way.
            after(env["IDLE"] != nil ? 5.5 : env["TAP"] != nil ? 2.6 + (Double(env["TAP"]!) ?? 0.2) : 2.5) {
                if let image = picture() { save(image, shot) }
                print("picture on \(window.screen?.localizedName ?? "no screen") at \(window.backingScaleFactor)x, window at \(window.frame.origin)")
                exit(0)
            }
        }
        // ANIM=<png> checks the bar's change of shape in two ways. Pictures: the glide frozen at five points, side by
        // side, to see each in-between shape is whole. Timing: a real widening and narrowing with no pictures taken
        // (a capture blocks the main thread and would itself make the glide jump), which must move in small, close steps.
        if let anim = env["ANIM"] {
            var frames: [CGImage] = []
            for (i, point) in [0, 0.25, 0.5, 0.75, 1].enumerated() {
                after(2.0 + Double(i) * 0.3) { SoftScroller.pin = point; scroll(400 + CGFloat(i)) } // a scroll shows the bar and places it
                after(2.2 + Double(i) * 0.3) { if let image = picture()?.cropping(to: CGRect(x: 630, y: 590, width: 120, height: 140)) { frames.append(image) } }
            }
            let redraw = { () -> Void in scrollView(in: window.contentView!)?.verticalScroller?.needsDisplay = true } // as the system does on mouse enter and exit
            after(3.6) { SoftScroller.pin = nil; scroll(410); SoftScroller.steps = []; SoftScroller.forceWide = true; redraw() }
            after(4.1) { SoftScroller.forceWide = false; redraw() }
            after(4.6) {
                let strip = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120 * frames.count, pixelsHigh: 140, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: strip)
                for (i, frame) in frames.enumerated() { NSGraphicsContext.current!.cgContext.draw(frame, in: CGRect(x: i * 120, y: 0, width: 120, height: 140)) }
                try? strip.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: anim))
                let steps = SoftScroller.steps
                let moving = zip(steps, steps.dropFirst()).filter { $0.width != $1.width }
                let jump = moving.map { abs($1.width - $0.width) }.max() ?? 0
                let gap = moving.map { ($1.time - $0.time) * 1000 }.max() ?? 0
                print("widths:", steps.map { String(format: "%.1f", $0.width) }.joined(separator: " "))
                print(String(format: "glide: %d steps, largest jump %.2f pt, longest pause %.0f ms", moving.count, jump, gap))
                precondition(steps.contains { $0.width > 10.9 } && steps.last!.width < 6.1, "the bar did not widen and narrow")
                precondition(jump < 1 && gap < 34, "the glide is not smooth")
                exit(0)
            }
        }
    }
    if bench {
        var steps: [(String, () -> Void)] = []
        for _ in 1...6 { steps += [("open picker", { catalog.picking = true }), ("close picker", { catalog.picking = false })] }
        steps.append(("open picker", { catalog.picking = true }))
        for y in Array(stride(from: 0, through: 2100, by: 140)) + Array(stride(from: 2100, through: 0, by: -140)) { steps.append(("scroll the list", { scroll(CGFloat(y)) })) }
        for q in ["c", "ca", "cal", "calc", "cal", "ca", "c", "", "s", "sa", "saf", "sa", "s", ""] + ["т", "те", "тер", "те", "т", ""] {
            steps.append(("type in search", { catalog.query = q }))
        }
        var marks: [(CFAbsoluteTime, String)] = []
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(i) * 0.25) { marks.append((CFAbsoluteTimeGetCurrent(), step.0)); step.1() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(steps.count) * 0.25) {
            let first = marks.first?.0 ?? 0
            print(String(format: "build and show the window: %.0f ms", stalls.filter { $0.0 < first }.map(\.1).reduce(0, +)))
            for name in ["open picker", "close picker", "scroll the list", "type in search"] {
                let hits = marks.filter { $0.1 == name }.map { m in stalls.filter { $0.0 >= m.0 && $0.0 < m.0 + 0.25 }.map(\.1).reduce(0, +) }
                print(String(format: "%@ ×%d: avg %.0f ms, worst %.0f ms", name, hits.count, hits.reduce(0, +) / Double(hits.count), hits.max() ?? 0))
            }
            if let bar = scrollView(in: window.contentView!)?.verticalScroller {
                // The track shows only under the mouse; the always-on style draws it at once, so the check does not need a mouse.
                let (style, before) = (bar.scrollerStyle, SoftScroller.trackDraws)
                bar.scrollerStyle = .legacy
                bar.display()
                bar.scrollerStyle = style
                print("scroll bar: \(type(of: bar)), width \(Int(bar.frame.width)) pt, adopted \(SoftTrack.Probe.adopted) scroller(s), our track drawn \(SoftScroller.trackDraws - before) time(s) on demand, \(SoftScroller.trackDraws) in all")
            }
            exit(0)
        }
    }
    app.run()
}

/// Main-thread busy periods over 16 ms (one dropped frame), as (end time, ms). Filled only after watchStalls().
var stalls: [(CFAbsoluteTime, Double)] = []

func watchStalls() {
    var start = CFAbsoluteTimeGetCurrent()
    let begin = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, .min) { _, _ in
        start = CFAbsoluteTimeGetCurrent()
    }
    let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, .max) { _, _ in
        let now = CFAbsoluteTimeGetCurrent()
        if now - start > 0.016 { stalls.append((now, (now - start) * 1000)) }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), begin, .commonModes)
    CFRunLoopAddObserver(CFRunLoopGetMain(), end, .commonModes)
}

final class Delegate: NSObject, NSApplicationDelegate {
    private var asked: DispatchSourceSignal?

    /// Quit from the menu or at logout: the journal's last changes go to disk first.
    func applicationWillTerminate(_: Notification) { Journal.shared.store(wait: true) }

    func applicationDidFinishLaunching(_: Notification) {
        // Asked to stop by a signal (a newer copy taking over, `kill`): the same, then leave with an error code, so
        // that the system's launch agent starts Zaslon again exactly as it did before this handler existed.
        signal(SIGTERM, SIG_IGN)
        let asked = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        asked.setEventHandler {
            Journal.shared.store(wait: true)
            exit(1)
        }
        asked.resume()
        self.asked = asked
        Catalog.shared.keepAutostart() // also warms the app list and icons, so the first "Add" is instant
        TunnelProxy.shared.start()
        Gate.shared.start()
        Gate.shared.watch()
        Updater.shared.watch()
        guard !UserDefaults.standard.bool(forKey: "askedLogin") else { return }
        UserDefaults.standard.set(true, forKey: "askedLogin")
        let a = NSAlert()
        a.messageText = t("Запускать Zaslon при входе в систему?", "Start Zaslon at login?")
        a.informativeText = t("Без автозапуска защита не работает, пока вы не откроете программу сами. Поменять можно в окне программы.", "Without autostart the protection does not work until you open the app yourself. You can change this in the app's window.")
        a.addButton(withTitle: t("Запускать", "Start at login"))
        a.addButton(withTitle: t("Не сейчас", "Not now"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Catalog.shared.setLogin(true) }
    }
}

/// Tray symbol 20% larger than the 13 pt default; a plain Image(systemName:) cannot be resized in a MenuBarExtra label.
func trayIcon(_ name: String) -> Image {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: "Zaslon")!
        .withSymbolConfiguration(.init(pointSize: 15.6, weight: .regular))!
    img.isTemplate = true
    return Image(nsImage: img)
}

struct ZaslonApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate
    @StateObject private var g = Guard()

    var body: some Scene {
        MenuBarExtra {
            Panel(g: g)
        } label: {
            trayIcon(g.freezing ? "pause.circle.fill" : g.enabled ? "shield" : "shield.slash")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Choice: Identifiable {
    let id: String // bundle path
    let name: String
    let icon: NSImage // 18 pt thumbnail
}

/// Running and installed apps, running first.
/// Listed inside the panel on purpose: any second window (NSOpenPanel) takes focus and closes the tray window.
func appPaths() -> [(path: String, name: String)] {
    let fm = FileManager.default
    var seen: Set = [Bundle.main.bundlePath]
    func app(_ path: String) -> (path: String, name: String)? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard seen.insert(real).inserted else { return nil }
        let name = fm.displayName(atPath: real)
        return (real, name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }
    let byName: ((path: String, name: String), (path: String, name: String)) -> Bool = {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
    let running = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular }
        .compactMap { $0.bundleURL?.path }.compactMap(app).sorted(by: byName)
    // One level of subfolders covers /Applications/Utilities and vendor folders.
    let installed = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"].flatMap { dir in
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).flatMap { item -> [String] in
            let p = dir + "/" + item
            if item.hasSuffix(".app") { return [p] }
            return ((try? fm.contentsOfDirectory(atPath: p)) ?? []).filter { $0.hasSuffix(".app") }.map { p + "/" + $0 }
        }
    }.compactMap(app).sorted(by: byName)
    return running + installed
}

/// A system icon holds reps up to 2048 px and decodes them on first draw (4–25 ms each, measured).
/// Drawing it once into a 36 px bitmap makes every later draw free.
func thumbnail(_ path: String) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 18, height: 18)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

/// The app list, its icons and the login-item state. All of it is slow (disk, LaunchServices, XPC, icon decoding),
/// so it is built on a background queue and the panel only reads the finished result.
final class Catalog: ObservableObject {
    static let shared = Catalog()
    @Published var apps: [Choice] = []
    @Published var login = false
    @Published var picking = false // the picker is open
    @Published var query = ""
    private let queue = DispatchQueue(label: "zaslon.catalog", qos: .userInitiated)
    private var thumbs: [String: NSImage] = [:] // touched on `queue` only

    func refresh() {
        queue.async {
            let login = Self.agent.status == .enabled || SMAppService.mainApp.status == .enabled
            let apps = appPaths().map { app -> Choice in
                if self.thumbs[app.path] == nil { self.thumbs[app.path] = thumbnail(app.path) }
                return Choice(id: app.path, name: app.name, icon: self.thumbs[app.path]!)
            }
            DispatchQueue.main.async {
                if self.login != login { self.login = login }
                if self.apps.map(\.id) != apps.map(\.id) { self.apps = apps }
            }
        }
    }

    /// Login item via the system's own list (System Settings → Login Items).
    /// Autostart has two parts. The launch agent inside the app bundle: the system starts it at login, before ordinary
    /// login items, and starts it again after a crash (quitting from the menu is a clean exit and is left alone).
    /// And the plain login item, as a fallback: see keepAutostart().
    static let agent = SMAppService.agent(plistName: agentLabel + ".plist")

    func setLogin(_ on: Bool) {
        login = on // show the click at once; refresh() below corrects it if the system refused
        queue.async {
            do {
                if on {
                    try? SMAppService.mainApp.register()
                    try Self.agent.register()
                    if Self.agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    try? SMAppService.mainApp.unregister()
                    // Removing the agent makes the system stop the copy it started, which is this one. Protection
                    // must not end with the switch, so a plain copy is started right after.
                    if managed { relaunchSoon() }
                    try Self.agent.unregister()
                }
            } catch { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
        }
        refresh()
    }

    /// Keeps both parts of autostart in place while it is switched on, and repairs the agent. The system refuses to
    /// start the agent once the app has been rebuilt or moved (it exits with code 78 before our code runs, seen
    /// after a rebuild) and keeps refusing until the agent is registered again. The login item still starts the app
    /// then, and this is where the agent gets repaired; the repaired agent starts its own copy, which takes over.
    func keepAutostart() {
        DispatchQueue.global(qos: .utility).async {
            let (item, agent) = (SMAppService.mainApp, Self.agent)
            guard item.status == .enabled || agent.status == .enabled else { return } // autostart is off
            if item.status != .enabled { try? item.register() }
            guard !managed else { return }
            // Autostart is on, yet the agent did not start this copy: it is missing or broken, so it is registered
            // afresh. A repaired agent starts its own copy at once and that copy ends this one. Still being here a
            // few seconds later means the repair did not take (seen: the first attempt right after a rebuild).
            for _ in 0..<4 {
                let gone = DispatchSemaphore(value: 0)
                agent.unregister { _ in gone.signal() }
                _ = gone.wait(timeout: .now() + 5)
                Thread.sleep(forTimeInterval: 1)
                try? agent.register()
                if agent.status == .requiresApproval { return } // switched off in System Settings: the user's call
                Thread.sleep(forTimeInterval: 5)
            }
        }
        refresh()
    }
}

/// The system scroll bar with a faint track instead of the near-black one, and a smooth change between its thin
/// (idle) and wide (under the mouse) shapes.
///
/// The system draws a bar through two layers of its own and resizes them in one jump; anything drawn into them is
/// cut to the current shape (seen in recorded frames), and draw(_:) is never called. So the system's layers are
/// left empty and the visible knob and track are two layers of our own, placed from rect(for: .knob), which says
/// where the knob is and which shape the system wants. The width glides between the two shapes on a timer.
final class SoftScroller: NSScroller {
    static var trackDraws = 0 // read by --bench to prove this class is the one in use
    // For the transition check (ANIM=…), which has no mouse:
    static var steps: [(time: CFTimeInterval, width: CGFloat)] = [] // every knob width shown, and when
    static var forceWide: Bool? // asks for a shape
    static var pin: CGFloat? // freezes the glide at a point, 0…1
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_: NSPoint) -> NSView? { nil } // clicks belong to the scroller
    }

    private let canvas = Canvas()
    private let track = CALayer(), knob = CALayer()
    private var grow: CGFloat = 0 // 0 = thin … 1 = wide, as shown right now
    private var goal: CGFloat = 0
    private var thin = (x: CGFloat(8), w: CGFloat(6)) // replaced by the system's own numbers once seen
    private var wide = (x: CGFloat(3), w: CGFloat(11))
    private var ticker: Timer?
    private var fade: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.wantsLayer = true
        canvas.layer?.addSublayer(track)
        canvas.layer?.addSublayer(knob)
        addSubview(canvas)
        canvas.alphaValue = 0 // hidden until the list is scrolled
        tint()
    }

    /// Shows the bar now and fades it out after a pause, as the system does with its own bar. The system's fade
    /// does not reach our layers (seen in a capture taken 4 s after the last scroll), so it is done here.
    private func wake() {
        fade?.cancel()
        canvas.alphaValue = 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.goal == 0 else { return } // stays while the mouse is on it
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; self.canvas.animator().alphaValue = 0 }
        }
        fade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError() }

    private func tint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            knob.backgroundColor = NSColor.labelColor.withAlphaComponent(0.42).cgColor
        }
    }

    /// Reads which shape the system wants, starts gliding toward it if that changed, and places the layers.
    private func sync() {
        let system = rect(for: .knob)
        if system.width > 8 { wide = (system.minX, system.width) } else if system.width > 0 { thin = (system.minX, system.width) }
        let want: CGFloat = Self.forceWide ?? (system.width > 8) ? 1 : 0
        if want != goal {
            goal = want
            wake()
            ticker?.invalidate()
            let (from, start) = (grow, CACurrentMediaTime())
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                let t = min((CACurrentMediaTime() - start) / 0.22, 1)
                self.grow = from + (self.goal - from) * (1 - pow(1 - t, 3)) // ease-out: quick start, soft landing
                self.place()
                if t >= 1 { timer.invalidate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        place()
    }

    private func place() {
        let (system, slot) = (rect(for: .knob), rect(for: .knobSlot))
        let grow = Self.pin ?? grow
        let (x, w) = (thin.x + (wide.x - thin.x) * grow, thin.w + (wide.w - thin.w) * grow)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // the timer is the animation; implicit ones would lag the knob behind the list
        knob.isHidden = system.height <= 2 // nothing to scroll
        knob.frame = CGRect(x: x, y: system.minY + 1, width: w, height: max(system.height - 2, w))
        knob.cornerRadius = w / 2
        track.frame = CGRect(x: wide.x, y: slot.minY, width: wide.w, height: slot.height)
        track.cornerRadius = wide.w / 2
        track.opacity = Float(grow)
        CATransaction.commit()
        Self.steps.append((CACurrentMediaTime(), w))
    }

    // The scroll view sets these on every scroll step.
    override var doubleValue: Double {
        didSet {
            if doubleValue != oldValue { wake() }
            place()
        }
    }
    override var knobProportion: CGFloat { didSet { place() } }
    override func layout() {
        super.layout()
        place()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    // The system calls these when its own layers need new content, which includes every change of shape.
    // They draw nothing: the system's layers stay empty.
    override func drawKnobSlot(in _: NSRect, highlight _: Bool) {
        Self.trackDraws += 1
        sync()
    }

    override func drawKnob() { sync() }
}

/// Gives the enclosing scroll view a SoftScroller as its vertical bar. SwiftUI has no setting for the track colour and
/// creates the bar late, so this watches the property and replaces a plain scroller whenever one appears.
/// (Changing the class of the existing scroller does not work: AppKit then never calls the draw method, checked.)
struct SoftTrack: NSViewRepresentable {
    final class Probe: NSView {
        static var adopted = 0 // read by --bench
        private var watch: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            hook()
            DispatchQueue.main.async { self.hook() } // the scroll view may not be the parent yet on the first pass
        }

        private func hook() {
            guard watch == nil, let list = enclosingScrollView else { return }
            watch = list.observe(\.verticalScroller, options: [.initial, .new]) { list, _ in
                // The cap stops a tug of war if the system ever insists on its own scroller.
                guard let old = list.verticalScroller, !(old is SoftScroller), Self.adopted < 50 else { return }
                let bar = SoftScroller(frame: old.frame)
                (bar.scrollerStyle, bar.controlSize, bar.knobStyle) = (old.scrollerStyle, old.controlSize, old.knobStyle)
                Self.adopted += 1
                list.verticalScroller = bar
            }
        }
    }

    func makeNSView(context _: Context) -> Probe { Probe() }
    func updateNSView(_: Probe, context _: Context) {}
}

let corner: CGFloat = 6 // one rounding for every button and row

/// The system's small switch, drawn by hand. The system one turns grey whenever its window is not the active one,
/// so it looked switched off in pictures and differed between themes.
struct Switch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        // A button, so keyboard focus and Space still flip it; to VoiceOver it stays an ordinary switch.
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Color.green : Color.primary.opacity(0.18))
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5).padding(2)
                }
                .animation(.snappy(duration: 0.18), value: configuration.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// A window that never becomes active: pictures of it come out the same whatever else is on screen.
final class Still: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The interface language: Russian or English. Every string is written in place, as `t("русский", "English")`.
final class Lang: ObservableObject {
    static let shared = Lang()
    /// Starts from the system language; a choice made in the settings is remembered.
    @Published var code = UserDefaults.standard.string(forKey: "language") ?? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en")

    func choose(_ code: String) {
        self.code = code
        UserDefaults.standard.set(code, forKey: "language")
    }
}

func t(_ ru: String, _ en: String) -> String { Lang.shared.code == "ru" ? ru : en }

/// The shared look of a button or row: a rounded box that fills in under the mouse.
struct Chip: ViewModifier {
    static var showHover = false // HOVER=1 in the test window, to take a picture of the hover look
    var rest = 0.0 // fill while the mouse is away
    var outline = 0.0 // border
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: corner).fill(.primary.opacity(hover || Self.showHover ? rest + 0.12 : rest)))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.primary.opacity(outline), lineWidth: 0.5))
            .contentShape(Rectangle()) // the whole box takes the click, not only the glyphs
            .onHover { hover = $0 }
    }
}

struct StatusPill: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .modifier(Chip(rest: 0.07, outline: 0.15))
        }
        .buttonStyle(.plain)
    }
}

/// The round button that switches all protection on and off. Under the mouse it fills in and grows a little; a press
/// squeezes it; the shield redraws itself into the crossed-out one; switching on sends one ring outward.
struct ShieldButton: View {
    @ObservedObject var g: Guard
    @State private var hover = false
    @State private var rings = 0 // goes up on every switch-on and starts the ring

    private struct Ring {
        var scale = 1.0
        var opacity = 0.0
    }

    private struct Squeeze: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .animation(.snappy(duration: 0.18), value: configuration.isPressed)
        }
    }

    var body: some View {
        let lit = hover || Chip.showHover
        Button { withAnimation(.snappy(duration: 0.3)) { g.enabled.toggle() } } label: {
            Image(systemName: g.freezing ? "pause.fill" : g.enabled ? "shield" : "shield.slash")
                .font(.system(size: 16, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(g.freezing ? Color(nsColor: .windowBackgroundColor) : g.enabled ? .primary : .secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(.primary.opacity(g.freezing ? 1 : lit ? 0.12 : 0)))
                .overlay(Circle().strokeBorder(.primary.opacity(g.enabled ? 0.25 : 0.12), lineWidth: 0.5))
                .background(
                    Circle().strokeBorder(.primary, lineWidth: 1)
                        .keyframeAnimator(initialValue: Ring(), trigger: rings) { ring, value in
                            ring.scaleEffect(value.scale).opacity(value.opacity)
                        } keyframes: { _ in
                            KeyframeTrack(\.scale) {
                                CubicKeyframe(1, duration: 0.01)
                                CubicKeyframe(1.6, duration: 0.55)
                            }
                            KeyframeTrack(\.opacity) {
                                LinearKeyframe(0.4, duration: 0.05)
                                LinearKeyframe(0, duration: 0.5)
                            }
                        }
                )
                .scaleEffect(lit ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(Squeeze())
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hover = over } }
        .onChange(of: g.enabled) { _, on in if on { rings += 1 } }
    }
}

struct QuitButton: View {
    let action: () -> Void
    @ObservedObject private var lang = Lang.shared
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(t("Выйти", "Quit")).foregroundStyle(hover ? Color.red : .secondary).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

struct RemoveButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                .foregroundStyle(hover ? HierarchicalShapeStyle.primary : .tertiary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: corner).fill(.primary.opacity(hover ? 0.12 : 0)))
                .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(.primary.opacity(hover ? 0.25 : 0), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.padding(.trailing, -4)
    }
}

/// The settings, shown in place of the list: autostart, updates, language.
struct SettingsView: View {
    @ObservedObject var catalog: Catalog
    @ObservedObject var updater = Updater.shared
    @ObservedObject var lang = Lang.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(t("Настройки", "Settings")).font(.system(size: 15, weight: .semibold)).padding(.bottom, 12)
            Divider()
            HStack(spacing: 8) {
                Text(t("Запускать при входе", "Launch at login")).font(.system(size: 13))
                Spacer()
                Toggle(t("Запускать при входе", "Launch at login"), isOn: Binding(get: { catalog.login }, set: { catalog.setLogin($0) }))
                    .labelsHidden().toggleStyle(Switch())
            }
            .padding(.vertical, 9)
            Divider()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("Обновлять автоматически", "Update automatically")).font(.system(size: 13))
                    Text(updater.status).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                // Under Homebrew the formula owns the app: no switch, the line above says how to update.
                if !Updater.brewed {
                    Toggle(t("Обновлять автоматически", "Update automatically"), isOn: Binding(get: { updater.on }, set: { updater.choose($0) }))
                        .labelsHidden().toggleStyle(Switch())
                }
            }
            .padding(.vertical, 9)
            Divider()
            HStack(spacing: 8) {
                Text(t("Язык", "Language")).font(.system(size: 13))
                Spacer()
                // Two plain chips, not a system control: they look the same in both themes and in an inactive window.
                HStack(spacing: 4) {
                    ForEach([("ru", "Русский"), ("en", "English")], id: \.0) { code, name in
                        Button { lang.choose(code) } label: {
                            Text(name).font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3)
                                .foregroundStyle(lang.code == code ? HierarchicalShapeStyle.primary : .tertiary)
                                .modifier(Chip(rest: lang.code == code ? 0.1 : 0, outline: lang.code == code ? 0.2 : 0.1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 9)
            Divider()
            HStack {
                Spacer()
                Button(action: close) { Text(t("Закрыть", "Close")).padding(.vertical, 5).contentShape(Rectangle()) }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 12)
        }
    }
}

struct Panel: View {
    @ObservedObject var g: Guard
    @ObservedObject var catalog: Catalog
    @ObservedObject var gate = Gate.shared
    @ObservedObject var lang = Lang.shared // every string below is read again when the language changes
    /// What the window shows. The journal and the settings each take the whole window, in place of the list.
    enum Screen { case list, journal, settings }
    // In the test window GEAR=1 opens the settings and LOG=1 the journal.
    @State private var screen: Screen = ProcessInfo.processInfo.environment["GEAR"] != nil ? .settings : ProcessInfo.processInfo.environment["LOG"] != nil ? .journal : .list
    @FocusState private var searching: Bool

    init(g: Guard, catalog: Catalog = .shared) {
        self.g = g
        self.catalog = catalog
    }

    var body: some View {
        Group {
            switch screen {
            case .list: main
            case .journal: JournalView(journal: .shared) { screen = .list }
            case .settings: SettingsView(catalog: catalog) { screen = .list }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ShieldButton(g: g).help(g.enabled ? t("Выключить защиту", "Switch protection off") : t("Включить защиту", "Switch protection on"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).contentTransition(.opacity)
                    HStack(spacing: 0) {
                        Text(subtitle)
                        if g.freezing { Text(g.since, style: .timer) }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { screen = .journal } label: {
                    Image(systemName: "clock").font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).modifier(Chip())
                }
                .buttonStyle(.plain).help(t("Журнал обрывов", "Outage journal")).padding(.trailing, -8)
                Button { screen = .settings } label: {
                    Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).modifier(Chip())
                }
                .buttonStyle(.plain).help(t("Настройки", "Settings"))
            }
            .padding(.bottom, 14)
            Divider()
            ForEach(g.entries) { e in
                HStack(spacing: 8) {
                    let up = g.running.contains(e.id)
                    let off = e.off == true
                    // ChatGPT and Claude only: the gate's rule is missing, or a connection really leaves outside the VPN.
                    let service = Gate.services.map(\.app).first(where: e.matches.contains)
                    let unruled = service.map { !gate.ruled.contains($0) } ?? false
                    let past = service.map(gate.past.contains) ?? false
                    // red = no protection for this program, yellow = frozen or sending past the VPN, green = running, hollow = not running
                    Circle().fill(off || unruled ? Color.red : !up ? .clear : g.freezing || past ? .yellow : .green)
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: !up && !off && !unruled ? 1 : 0))
                        .frame(width: 7, height: 7).frame(width: 10)
                    Text(e.name).font(.system(size: 13))
                    Spacer()
                    StatusPill(text: off ? t("выключена", "off") : unruled ? t("не работает", "not working") : !up ? t("не запущен", "not running") : g.freezing ? t("на паузе", "frozen") : past ? t("мимо VPN", "outside VPN") : t("работает", "running")) {
                        if let service, unruled, !off {
                            gate.setRules(true, app: service) // asks for the admin password
                        } else if let i = g.entries.firstIndex(where: { $0.id == e.id }) {
                            g.entries[i].off = !off
                        }
                    }
                    .help(off ? t("Включить защиту для этой программы", "Switch protection on for this app") : unruled ? t("Серверы этой программы ещё не закрыты воротами VPN. Нажмите и введите пароль администратора.", "This app's servers are not behind the VPN gate yet. Click and enter the admin password.") : t("Выключить защиту для этой программы", "Switch protection off for this app"))
                    RemoveButton {
                        let drop = { g.entries.removeAll { $0.id == e.id } }
                        // The gate's rule leaves with the entry; if the password is refused, both stay.
                        if let service, gate.ruled.contains(service) { gate.setRules(false, app: service) { if $0 { drop() } } } else { drop() }
                    }
                    .help(t("Убрать из списка", "Remove from the list"))
                }
                .padding(.vertical, 9)
                Divider()
            }
            // The picker is always in the tree and only revealed. Measured with --bench: opening it costs 0–3 ms this way, 8–9 ms when rebuilt each time.
            let taken = Set(g.entries.flatMap(\.matches))
            let shown = catalog.apps.filter { !taken.contains($0.id) && (catalog.query.isEmpty || $0.name.localizedCaseInsensitiveContains(catalog.query)) }
            // The list reaches 6 pt past the content on the left (row hover) and 14 pt on the right, so the scroll bar
            // sits in the panel's right margin. `edge` pulls the rest back in line.
            let edge = EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 14)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 10)
                    TextField(t("Поиск программы", "Search apps"), text: $catalog.query).textFieldStyle(.plain).font(.system(size: 13)).focused($searching)
                }
                .padding(.vertical, 9).padding(edge)
                Divider().padding(edge)
                // Fixed height: the window does not resize while you type.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { c in
                            pickRow(c) {
                                catalog.picking = false
                                let add = { g.entries.append(Entry(name: c.name, matches: [c.id])) }
                                // ChatGPT and Claude come with the gate: no rule (password refused), no entry.
                                if Gate.services.contains(where: { $0.app == c.id }), !gate.ruled.contains(c.id) {
                                    gate.setRules(true, app: c.id) { if $0 { add() } }
                                } else {
                                    add()
                                }
                            }
                        }
                    }
                    .padding(.trailing, 8)
                    .background(SoftTrack())
                }
                .frame(height: 232)
                .overlay {
                    if shown.isEmpty {
                        Text(catalog.apps.isEmpty ? t("Загружаю список", "Loading the list") : t("Ничего не найдено", "Nothing found")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                Divider().padding(edge)
            }
            .frame(height: catalog.picking ? nil : 0, alignment: .top).clipped()
            .padding(.leading, -edge.leading).padding(.trailing, -edge.trailing)
            .opacity(catalog.picking ? 1 : 0).disabled(!catalog.picking).accessibilityHidden(!catalog.picking)
            HStack(spacing: 14) {
                Button {
                    catalog.query = ""
                    catalog.picking.toggle()
                    searching = catalog.picking
                    if catalog.picking { catalog.refresh() } // picks up apps started or installed since launch; the cached list shows meanwhile
                } label: {
                    HStack(spacing: 4) { // tighter than a Label, which leaves the text far from the icon
                        Image(systemName: catalog.picking ? "xmark" : "plus").font(.system(size: 10, weight: .medium))
                        Text(catalog.picking ? t("Отмена", "Cancel") : t("Добавить", "Add"))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize().padding(.horizontal, 10).padding(.vertical, 5)
                        .modifier(Chip(outline: 0.25))
                }
                Spacer()
                QuitButton {
                    g.thawAll()
                    NSApp.terminate(nil)
                }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 12)
        }
    }

    var title: String {
        if !g.enabled { return t("Защита на паузе", "Protection paused") }
        switch g.protected {
        case nil: return t("Проверяю", "Checking")
        case true?: return t("Защищено", "Protected")
        case false?: return t("Заморожено", "Frozen")
        }
    }

    var subtitle: String {
        switch g.protected {
        case nil: return t("Спрашиваю WARP", "Asking WARP")
        case true?: return t("WARP подключён", "WARP connected")
        case false?: return g.freezing ? t("WARP отключён, ", "WARP disconnected, ") : t("WARP отключён, программы работают", "WARP disconnected, apps are running")
        }
    }

    func pickRow(_ c: Choice, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // The plus is on the left, under the status dots, away from the scroll bar on the right.
                Image(systemName: "plus").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary).frame(width: 10)
                Image(nsImage: c.icon).frame(width: 18, height: 18)
                Text(c.name).font(.system(size: 13)).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).modifier(Chip())
    }
}
