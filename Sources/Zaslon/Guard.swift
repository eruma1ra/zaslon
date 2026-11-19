import Darwin
import Foundation
import Network
import os

struct Proc {
    let pid: pid_t
    let ppid: pid_t
    let path: String // where the executable is now; empty once the file is deleted
    var origin = "" // where it was started from, as the kernel recorded at launch
    var jobLeader = false // leads a job in a terminal, the process its shell waits on: never stopped (see apply)
}

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// "/Applications/X.app" matches every executable inside the bundle; a bare name matches the executable's file name.
    var matches: [String]
    /// true = the user switched protection off for this one program. Optional so older saved lists still decode.
    var off: Bool?

    static let defaults = [
        Entry(name: "Claude", matches: ["/Applications/Claude.app", "claude"]),
        Entry(name: "ChatGPT + Codex", matches: ["/Applications/ChatGPT.app", "codex"]),
    ]
}

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    // Fails for other users' processes; we cannot signal those anyway.
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 ? info : nil
}

func listProcs() -> [Proc] {
    var pids = [pid_t](repeating: 0, count: 16384)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var buf = [CChar](repeating: 0, count: 4096)
    // An app update moves or deletes the binary of a process that is still running: proc_pidpath then points into
    // the updater's stash or returns nothing (both seen: an Electron app's helper, and Claude's chrome-native-host with no
    // path at all). The launch path the kernel keeps in the process's argument area does not change.
    var args = [CChar](repeating: 0, count: 1 << 16)
    return pids.prefix(Int(max(n, 0))).compactMap { pid in
        guard let info = bsdInfo(pid) else { return nil }
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        var (mib, size) = ([CTL_KERN, KERN_PROCARGS2, pid], args.count - 1)
        let origin = sysctl(&mib, 3, &args, &size, nil, 0) == 0 && size > 4 ? args.withUnsafeBufferPointer { String(cString: $0.baseAddress! + 4) } : ""
        return Proc(pid: pid, ppid: pid_t(info.pbi_ppid), path: len > 0 ? String(cString: buf) : "", origin: origin,
                    jobLeader: info.e_tdev != UInt32(bitPattern: -1) && info.pbi_pgid == UInt32(pid)) // NODEV: no terminal
    }
}

/// The entry's processes plus everything they started (MCP servers, shells, curl, git).
func tree(of entry: Entry, in procs: [Proc]) -> Set<pid_t> {
    let roots = procs.filter { p in
        entry.matches.contains { m in
            [p.path, p.origin].contains { m.hasPrefix("/") ? runs($0, from: m) : ($0 as NSString).lastPathComponent == m }
        }
    }
    return descendants(of: Set(roots.map(\.pid)), in: procs)
}

/// Whether an executable belongs to an app: it sits in the app's bundle, or in the app's own folder in Application
/// Support. An app that updates itself can leave old processes running from a copy stashed there, and its updater may
/// use sibling folders. Seen with an Electron app (bundle id com.example.app): a helper from before an
/// update, with launchd as its parent, ran from …/Application Support/com.example.app.beta/previous-bundle.
func runs(_ path: String, from app: String) -> Bool {
    if path.hasPrefix(app + "/") { return true }
    guard let stash = stash(of: app), path.hasPrefix(stash) else { return false }
    let next = path.dropFirst(stash.count).first
    return next == "/" || next == "." // <bundle id>/…, and siblings such as <bundle id>.beta/…
}

private var stashes: [String: String] = [:] // app path → its Application Support folder, "" when it has none
private func stash(of app: String) -> String? {
    if stashes[app] == nil {
        let id = app.hasSuffix(".app") ? Bundle(path: app)?.bundleIdentifier : nil
        stashes[app] = id.map { NSHomeDirectory() + "/Library/Application Support/" + $0 } ?? ""
    }
    return stashes[app]!.isEmpty ? nil : stashes[app]
}

func descendants(of roots: Set<pid_t>, in procs: [Proc]) -> Set<pid_t> {
    var set = roots
    var grew = true
    while grew {
        grew = false
        for p in procs where set.contains(p.ppid) && !set.contains(p.pid) {
            set.insert(p.pid)
            grew = true
        }
    }
    return set
}

/// Tunnel interfaces that are up and hold an IPv4 address, as "utun4/100.96.0.2". WARP's is one of them.
/// Reading this takes microseconds, against 30–75 ms for asking warp-cli.
func tunnels() -> Set<String> {
    var (found, head) = (Set<String>(), UnsafeMutablePointer<ifaddrs>?.none)
    guard getifaddrs(&head) == 0 else { return found }
    defer { freeifaddrs(head) }
    var next = head
    while let item = next {
        next = item.pointee.ifa_next
        let (name, up) = (String(cString: item.pointee.ifa_name), UInt32(IFF_UP | IFF_RUNNING))
        guard name.hasPrefix("utun"), item.pointee.ifa_flags & up == up,
              let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            found.insert(name + "/" + String(cString: host))
        }
    }
    return found
}

func parseWarp(_ output: String) -> Bool {
    output.contains("Status update: Connected")
}

/// Anything but a clear "Connected" counts as unprotected: a missing or hung warp-cli freezes the list.
func warpConnected() -> Bool {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/local/bin/warp-cli")
    p.arguments = ["status"]
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    // A healthy answer takes 30–75 ms. While this call hangs, the last answer stands, so the wait is kept short.
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return parseWarp(String(decoding: data, as: UTF8.self))
}

final class Guard: ObservableObject {
    @Published var entries: [Entry] { didSet { if live { save() }; apply() } }
    @Published var protected: Bool? // nil until the first check
    @Published var enabled = true { didSet { apply() } }
    @Published var since = Date()
    /// Entries that have at least one live process. A set, not counts: counts change every second and each change redraws the panel.
    @Published var running = Set<UUID>()

    var list: () -> [Proc] = listProcs
    var signal: (pid_t, Int32) -> Void = { _ = kill($0, $1) }

    private(set) var frozen = Set<pid_t>()
    private let live: Bool
    private var checking = false
    private var first = true
    private let monitor = NWPathMonitor()
    private var ticks = 0
    /// The tunnels that existed at the last "connected" answer. Written on the main thread, read by the tripwire.
    private let known = OSAllocatedUnfairLock(initialState: Set<String>())
    private var wire: DispatchSourceTimer?
    private var noted: Bool? // the connection state the journal has seen last

    /// Unknown counts as unprotected: the list is frozen from the first moment and thawed by the first "connected".
    var freezing: Bool { protected != true && enabled }

    init(entries: [Entry]? = nil, live: Bool = true) {
        self.live = live
        let saved = UserDefaults.standard.data(forKey: "entries").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
        self.entries = entries ?? (live ? saved : nil) ?? Entry.defaults
        guard live else { return }
        // warp-cli is asked twice a second while all is well, and ten times a second during a drop, so that a
        // program started meanwhile is frozen within a tenth of a second and the thaw comes quickly.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ticks += 1
            if self.protected != true || self.ticks % 5 == 0 { self.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        // The tripwire: twenty times a second, are the tunnels from the last "connected" answer still there?
        // A drop is then caught within 50 ms instead of 500. It can only freeze, never thaw: warp-cli decides that.
        // ponytail: still polling, so up to 50 ms of traffic can leave after a drop. A Network Extension is the only zero.
        let wire = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        wire.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        wire.setEventHandler { [weak self] in
            guard let self, self.cut(tunnels()) else { return }
            DispatchQueue.main.async { self.trip() }
        }
        wire.resume()
        self.wire = wire
        monitor.pathUpdateHandler = { [weak self] _ in DispatchQueue.main.async { self?.check() } }
        monitor.start(queue: .global())
        apply() // freeze first, ask second
        check()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "entries")
    }

    func check() {
        guard !checking else { return }
        checking = true
        let list = list
        // While WARP is up and nothing is frozen, the process scan only feeds the dots in the window, so one scan
        // in four is enough (every 2 s). Measured: scanning on every answer cost 4% of a core around the clock.
        let scan = protected != true || !frozen.isEmpty || ticks % 20 == 0
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = warpConnected()
            let nets = ok ? tunnels() : []
            let procs = scan || !ok ? list() : nil // off the main thread: a scan takes 5–10 ms
            DispatchQueue.main.async {
                self.checking = false
                if ok { self.learn(nets) }
                if let procs { self.update(ok, procs) } // nil: still connected, nothing to do
            }
        }
    }

    /// Remembers which tunnels exist while WARP says it is connected.
    func learn(_ nets: Set<String>) { known.withLock { $0 = nets } }

    /// True when a tunnel from the last "connected" answer is gone.
    func cut(_ now: Set<String>) -> Bool { known.withLock { !$0.isEmpty && !$0.isSubset(of: now) } }

    /// The tripwire fired: freeze now, then ask warp-cli what is going on.
    func trip() {
        learn([]) // one trip per drop; the next "connected" answer arms it again
        update(false)
        if live { check() }
    }

    func update(_ ok: Bool, _ procs: [Proc]? = nil) {
        if protected != ok {
            protected = ok
            since = Date()
        }
        apply(procs)
    }

    func apply(_ scanned: [Proc]? = nil) {
        let procs = scanned ?? list()
        var all = Set<pid_t>(), released = Set<pid_t>()
        var up = Set<UUID>()
        // Never stop a terminal job leader (an interactive claude or codex). On SIGSTOP its shell sees the job stop and
        // takes the terminal back; after SIGCONT the program's next read fails and it exits, so every drop would end the
        // terminal session. Its children are stopped as usual: they are not the shell's children, so it never notices.
        // The leader's own traffic to the gated services has no window; other traffic from it can leave during a drop.
        let leaders = Set(procs.filter(\.jobLeader).map(\.pid))
        for e in entries {
            let t = tree(of: e, in: procs).subtracting(leaders)
            if !t.isEmpty { up.insert(e.id) }
            if e.off == true { released.formUnion(t) } else { all.formUnion(t) }
        }
        released.subtract(all)
        all.remove(getpid())
        if first {
            // A previous run may have died with these frozen; they are switched off now, so they thaw at once.
            // (The rest of the list is frozen by the first pass anyway and thaws with the first "connected".)
            first = false
            frozen.formUnion(released)
        }
        // While unprotected nothing thaws: a child whose parent was force-quit drops out of the tree but stays frozen.
        let alive = Set(procs.map(\.pid))
        let target = freezing ? all.union(frozen.intersection(alive).subtracting(released)) : []
        for pid in target { signal(pid, SIGSTOP) }
        for pid in frozen.subtracting(target) { signal(pid, SIGCONT) }
        frozen = target
        if running != up { running = up }
        // The journal is fed here and nowhere else: every freeze is decided in this function, whatever led to it
        // (a drop, the shield, a change to the list), and the stop signals above have already been sent.
        guard live else { return }
        if noted == true, protected == false { Journal.shared.mark(connected: false, off: !enabled) }
        if noted == false, protected == true { Journal.shared.mark(connected: true) }
        noted = protected
        if protected == false, freezing { Journal.shared.froze(entries.filter { up.contains($0.id) && $0.off != true }.map(\.name)) }
    }

    func thawAll() {
        for pid in frozen { signal(pid, SIGCONT) }
        frozen = []
    }
}

func selftest() {
    print("tunnels now:", tunnels().sorted().joined(separator: ", "))
    var scanned = 0
    let scan = Date()
    for _ in 0..<5 { scanned = listProcs().count }
    print("scan: \(scanned) processes in \(Int(Date().timeIntervalSince(scan) * 200)) ms (runs off the main thread, twice a second)")
    precondition(listProcs().first { $0.pid == getpid() }?.origin.hasSuffix("/Zaslon") == true, "a process's launch path is readable")
    let started = Date()
    let apps = appPaths()
    precondition(apps.count > 5 && apps.allSatisfy { $0.path.hasSuffix(".app") && !$0.name.isEmpty })
    let icon = thumbnail(apps[0].path)
    precondition(icon.size == NSSize(width: 18, height: 18) && icon.representations.first?.pixelsWide == 36)
    print("picker: \(apps.count) apps listed in \(Int(Date().timeIntervalSince(started) * 1000)) ms (runs off the main thread)")

    precondition(parseWarp("Status update: Connected\nNetwork: healthy"))
    precondition(!parseWarp("Status update: Disconnected\nReason: Manual Disconnection"))
    precondition(!parseWarp("Status update: Connecting"))
    precondition(!parseWarp(""))

    // Logic on a fake process table.
    let app = Entry(name: "App", matches: ["/Applications/App.app", "tool"])
    var procs = [
        Proc(pid: 10, ppid: 1, path: "/Applications/App.app/Contents/MacOS/App"),
        Proc(pid: 11, ppid: 10, path: "/usr/bin/curl"),
        Proc(pid: 12, ppid: 11, path: "/bin/sh"),
        Proc(pid: 20, ppid: 1, path: "/opt/bin/tool"),
        Proc(pid: 30, ppid: 1, path: "/Applications/Application.app/Contents/MacOS/X"),
        Proc(pid: 31, ppid: 1, path: "/opt/bin/tool2"),
    ]
    precondition(tree(of: app, in: procs) == [10, 11, 12, 20])
    let moved = [Proc(pid: 40, ppid: 1, path: "", origin: "/Applications/App.app/Contents/Helpers/h"), Proc(pid: 41, ppid: 1, path: "/stash/x", origin: "/opt/bin/tool")]
    precondition(tree(of: app, in: moved) == [40, 41], "a process whose binary was moved or deleted is found by its launch path")
    precondition(runs("/Applications/App.app/Contents/MacOS/App", from: "/Applications/App.app"))
    precondition(!runs("/Applications/App.app.evil/x", from: "/Applications/App.app") && !runs("/Applications/Apple/x", from: "/Applications/App.app"))

    var sent: [(pid_t, Int32)] = []
    let g = Guard(entries: [app], live: false)
    g.list = { procs }
    g.signal = { sent.append(($0, $1)) }
    g.apply() // launch: nothing is known yet
    precondition(Set(sent.map(\.0)) == [10, 11, 12, 20] && sent.allSatisfy { $0.1 == SIGSTOP }, "the list is frozen before the first answer")
    sent = []
    g.update(true)
    precondition(Set(sent.map(\.0)) == [10, 11, 12, 20] && sent.allSatisfy { $0.1 == SIGCONT }, "the first \"connected\" thaws it")
    sent = []
    g.update(false)
    precondition(Set(sent.map(\.0)) == [10, 11, 12, 20] && sent.allSatisfy { $0.1 == SIGSTOP })
    // Parent force-quit: the orphan stays frozen while unprotected.
    procs.removeAll { $0.pid == 10 || $0.pid == 11 }
    procs[0] = Proc(pid: 12, ppid: 1, path: "/bin/sh")
    sent = []
    g.apply()
    precondition(g.frozen == [12, 20] && !sent.contains { $0.1 == SIGCONT && g.frozen.contains($0.0) })
    sent = []
    g.update(true)
    precondition(Set(sent.map(\.0)) == [12, 20] && sent.allSatisfy { $0.1 == SIGCONT } && g.frozen.isEmpty)
    g.update(false)
    g.enabled = false
    precondition(g.frozen.isEmpty, "pausing the guard thaws")

    // The tripwire: a tunnel that was there at the last "connected" answer is gone.
    g.enabled = true
    g.update(true)
    g.learn(["utun4/100.96.0.1", "utun9/10.0.0.1"])
    precondition(!g.cut(["utun4/100.96.0.1", "utun9/10.0.0.1", "utun7/10.1.1.1"]) && g.cut(["utun9/10.0.0.1"]))
    g.learn([])
    precondition(!g.cut([]), "nothing learned, nothing to trip on")
    g.learn(["utun4/100.96.0.1"])
    sent = []
    g.trip()
    precondition(g.protected == false && sent.contains { $0.1 == SIGSTOP } && !g.cut([]), "a trip freezes at once and disarms itself")
    g.enabled = false

    // A terminal job leader is never stopped: its shell takes the terminal back on SIGSTOP, and after SIGCONT the
    // program's next read fails and it exits. Its children are still frozen. An entry with only a leader is not frozen.
    let g3 = Guard(entries: [Entry(name: "C", matches: ["claude"])], live: false)
    g3.list = { [Proc(pid: 50, ppid: 1, path: "/usr/local/bin/claude", jobLeader: true),
                 Proc(pid: 51, ppid: 50, path: "/usr/local/bin/node"),
                 Proc(pid: 52, ppid: 1, path: "/usr/local/bin/claude")] }
    g3.signal = { sent.append(($0, $1)) }
    sent = []
    g3.update(false)
    precondition(g3.frozen == [51, 52] && !sent.contains { $0.0 == 50 }, "a terminal job leader is not stopped")
    g3.list = { [Proc(pid: 50, ppid: 1, path: "/usr/local/bin/claude", jobLeader: true)] }
    g3.update(false)
    precondition(g3.frozen.isEmpty && g3.running.isEmpty, "an entry with only a job leader does not count as frozen")

    // Switching one program off while unprotected thaws just that program.
    let g2 = Guard(entries: [Entry(name: "A", matches: ["a"]), Entry(name: "B", matches: ["b"])], live: false)
    g2.list = { [Proc(pid: 40, ppid: 1, path: "/x/a"), Proc(pid: 41, ppid: 1, path: "/x/b")] }
    g2.signal = { sent.append(($0, $1)) }
    g2.update(false)
    sent = []
    g2.entries[1].off = true
    precondition(g2.frozen == [40] && sent.contains { $0.0 == 41 && $0.1 == SIGCONT })

    // Real signals on a throwaway process tree.
    let stopped = { (pid: pid_t) in bsdInfo(pid)?.pbi_status == 4 } // SSTOP
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 60 & wait"]
    try! p.run()
    usleep(300_000)
    let pids = descendants(of: [p.processIdentifier], in: listProcs())
    precondition(pids.count == 2, "sh and its sleep child")
    for pid in pids { kill(pid, SIGSTOP) }
    usleep(100_000)
    precondition(pids.allSatisfy(stopped), "tree is stopped")
    for pid in pids { kill(pid, SIGCONT) }
    usleep(100_000)
    precondition(!pids.contains(where: stopped), "tree runs again")
    for pid in pids { kill(pid, SIGKILL) }
    // The gate: server name from a TLS hello, the DNS answerer's reply, reading a DNS reply, the list of names.
    func two(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
    let name = Array("api.chatgpt.com".utf8)
    let sni: [UInt8] = [0, 0] + two(name.count + 5) + two(name.count + 3) + [0] + two(name.count) + name
    let body: [UInt8] = [3, 3] + [UInt8](repeating: 7, count: 32) + [0, 0, 2, 0x13, 0x01, 1, 0] + two(sni.count) + sni
    let hello: [UInt8] = [0x16, 3, 1] + two(body.count + 4) + [1, 0] + two(body.count) + body
    precondition(serverName(hello) == "api.chatgpt.com", "the server name is read from a TLS hello")
    precondition(serverName(Array(hello.prefix(60))) == nil && serverName(Array("GET / HTTP/1.1".utf8)) == nil, "a cut or foreign first packet has no name")
    var question = dnsQuery("chatgpt.com")
    precondition(dnsAddresses(dnsAnswer(question)!) == ["127.0.0.1"], "an IPv4 question is answered with this Mac")
    question[question.count - 3] = 28 // the same question for IPv6
    precondition(dnsAddresses(dnsAnswer(question)!).isEmpty && dnsAnswer([1, 2, 3]) == nil, "other questions get an empty answer, junk gets none")
    precondition(Gate.covers("ab.chatgpt.com") && Gate.covers("claude.ai") && !Gate.covers("notchatgpt.com") && !Gate.covers("example.com"), "the gate forwards only the listed services")
    precondition(Gate.ours("nameserver 127.0.0.1\nport 5354\n") && !Gate.ours("nameserver 10.0.0.1\n"), "only our own DNS rule counts and is removed")
    let vpn: Set<String> = ["100.96.0.2", "2001:db8::7"]
    precondition(!outside(local: "100.96.0.2", remote: "1.1.1.1", tunnel: vpn) && !outside(local: "2001:db8::7", remote: "2606:4700::1", tunnel: vpn), "a connection that starts from the tunnel is inside the VPN")
    precondition(outside(local: "192.168.1.7", remote: "1.1.1.1", tunnel: vpn) && outside(local: "2a02::7", remote: "2606:4700::1", tunnel: vpn), "a connection from the Wi-Fi address to the internet is outside")
    precondition(!outside(local: "192.168.1.7", remote: "192.168.1.1", tunnel: vpn) && !outside(local: "127.0.0.1", remote: "127.0.0.1", tunnel: vpn) && !outside(local: "fe80::1", remote: "fe80::2", tunnel: vpn), "loopback and the local network are not the internet")
    // The socket reader, on a connection of our own that never leaves this Mac.
    let (server, client) = (socket(AF_INET, SOCK_STREAM, 0), socket(AF_INET, SOCK_STREAM, 0))
    var here = ipv4("127.0.0.1", 0)!
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &here) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        precondition(bind(server, $0, length) == 0 && listen(server, 1) == 0 && getsockname(server, $0, &length) == 0 && connect(client, $0, length) == 0, "a loopback connection opens")
    } }
    precondition(connections(getpid()).contains { $0.local == "127.0.0.1" && $0.remote == "127.0.0.1" }, "the reader sees our own connection with both addresses right")
    precondition(!leavesOutside(getpid(), tunnelAddresses()), "this process has no connection outside the tunnel")
    close(client); close(server)
    // The journal: an outage opens once, collects what was frozen and refused, closes, and survives a restart.
    let (j, t0) = (Journal(file: nil), Date(timeIntervalSince1970: 1_800_000_000))
    j.refuse(); j.froze(["X"]); j.mark(connected: true, at: t0)
    precondition(j.outages.isEmpty, "nothing is written while no outage is open")
    j.mark(connected: false, at: t0); j.mark(connected: false, at: t0 + 5)
    j.froze(["Claude"]); j.froze(["ChatGPT", "Claude"]); j.refuse(); j.refuse()
    j.mark(connected: true, at: t0 + 163)
    precondition(j.outages.count == 1 && j.outages[0].frozen == ["Claude", "ChatGPT"] && j.outages[0].refused == 2 && j.outages[0].end == t0 + 163, "one outage with its facts")
    Lang.shared.code = "en"
    precondition(Journal.lasted(163) == "2 min 43 s" && Journal.lasted(28) == "28 s" && Journal.lasted(3900) == "1 h 5 min", "lengths read naturally")
    precondition(Journal.connections(1) == "1 connection" && Journal.connections(3) == "3 connections")
    Lang.shared.code = "ru"
    precondition(["1 соединение", "3 соединения", "11 соединений", "21 соединение", "25 соединений"] == [1, 3, 11, 21, 25].map(Journal.connections), "Russian counts take the right form")
    precondition(Journal.facts(j.outages[0]) == ["Заморожено: Claude, ChatGPT", "Ворота отказали: 2 соединения"])
    let journalFile = NSTemporaryDirectory() + "zaslon-journal-test.json"
    try? FileManager.default.removeItem(atPath: journalFile)
    let kept = Journal(file: journalFile)
    kept.outages = [Outage(start: t0, frozen: ["Claude"], off: true), Outage(start: t0 - 60, end: t0 - 59.6)]
    kept.store(wait: true)
    let read = Journal(file: journalFile).outages
    precondition(read.map(\.cut) == [true, nil] && abs(read[1].end!.timeIntervalSince(t0 - 59.6)) < 0.001, "an outage left open by a quit is read back as cut short; one under a second keeps its length")
    precondition(Journal.span(read[0]).hasSuffix("– ?") && !Journal.span(read[1]).hasSuffix("?"))
    precondition(Journal.facts(kept.outages[0]) == ["Заморожено: Claude"] && Journal.facts(Outage(start: t0, off: true)) == ["Защита была выключена"], "what was frozen is shown even if the outage began with protection off")
    try? FileManager.default.removeItem(atPath: journalFile)
    // The very lines that will run with admin rights, here without them and in a scratch folder.
    let folder = NSTemporaryDirectory() + "zaslon-rule-test"
    try? FileManager.default.removeItem(atPath: folder)
    Gate.run(Gate.ruleShell(true, Gate.domains, folder: folder), admin: false).waitUntilExit()
    let written = Gate.domains.map { (try? String(contentsOfFile: folder + "/" + $0, encoding: .utf8)) ?? "" }
    precondition(written.count == 8 && written.allSatisfy { $0 == "nameserver 127.0.0.1\nport 5354\n" }, "the rule script writes one rule file per domain")
    try? "nameserver 10.1.1.1\n".write(toFile: folder + "/claude.ai", atomically: true, encoding: .utf8) // somebody else's rule
    Gate.run(Gate.ruleShell(false, Gate.domains, folder: folder), admin: false).waitUntilExit()
    precondition((try? FileManager.default.contentsOfDirectory(atPath: folder)) == ["claude.ai"], "removing deletes our rule files and nobody else's")
    try? FileManager.default.removeItem(atPath: folder)
    print("selftest ok")
}

/// A fire drill that leaves the VPN alone: a throwaway Guard, with only the given programs in its list, is told that
/// WARP went down and, `seconds` later, that it is back. Same code as the real thing, real signals included.
func drill(seconds: Double, matches: [String]) {
    let entries = matches.map { Entry(name: ($0 as NSString).lastPathComponent, matches: [$0]) }
    func pids() -> Set<pid_t> {
        let procs = listProcs()
        return entries.reduce(into: Set<pid_t>()) { $0.formUnion(tree(of: $1, in: procs)) }
    }
    // Never freeze whoever runs the drill: that would be the terminal or the assistant session itself.
    let procs = listProcs()
    var (me, pid) = (Set<pid_t>(), getpid())
    while pid > 1, let proc = procs.first(where: { $0.pid == pid }) { me.insert(pid); pid = proc.ppid }
    guard pids().isDisjoint(with: me) else {
        print("refused: this list would freeze the process running the drill")
        exit(1)
    }
    func report(_ label: String) {
        let all = pids()
        print("\(label): \(all.count) processes, \(all.filter { bsdInfo($0)?.pbi_status == 4 }.count) frozen")
        fflush(stdout)
    }
    let g = Guard(entries: entries, live: false)
    report("before")
    print("pids:", pids().sorted().map(String.init).joined(separator: " "))
    g.apply() // as at launch: frozen before the first answer
    usleep(200_000)
    report("WARP down")
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { usleep(500_000); g.apply() } // the 0.5 s tick, which also catches programs started meanwhile
    report("still down")
    g.update(true)
    usleep(200_000)
    report("WARP back")
}

/// Lists, without touching anything, the processes an entry with these matches would freeze right now.
func cover(matches: [String]) {
    let procs = listProcs()
    let pids = tree(of: Entry(name: "", matches: matches), in: procs)
    for proc in procs where pids.contains(proc.pid) {
        print(proc.pid, "parent", proc.ppid, proc.path.isEmpty ? "(file gone) " + proc.origin : proc.path, proc.jobLeader ? "[terminal job leader: never stopped]" : "")
    }
    print("\(pids.count) processes, \(procs.filter { pids.contains($0.pid) && $0.jobLeader }.count) terminal job leaders")
    let inside = tunnelAddresses()
    var (links, count) = (0, [String: Int]())
    for proc in procs where pids.contains(proc.pid) {
        for link in connections(proc.pid) {
            links += 1
            // An outside connection is named with its process: that is the one to look at.
            let out = link.local != "0.0.0.0" && link.local != "::" && outside(local: link.local, remote: link.remote, tunnel: inside)
            count[(out ? "OUTSIDE the VPN  " : "") + link.local + " -> " + link.remote + (out ? "  [\(proc.pid) \((proc.path as NSString).lastPathComponent)]" : ""), default: 0] += 1
        }
    }
    for (line, n) in count.sorted(by: { $0.value > $1.value }) { print(String(format: "%4d  ", n) + line) }
    print("\(links) connections, tunnel addresses: \(inside.sorted().joined(separator: ", "))")
}
