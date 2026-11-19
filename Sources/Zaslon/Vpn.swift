import Foundation
import os

/// Which VPN Zaslon watches. WARP is asked through `warp-cli`, exactly as before this file existed. Happ (a client
/// for VLESS, Reality and the like; the protocol makes no difference here) has no such command, so the kernel is
/// asked instead: which tunnel interface does a process of the Happ app hold open.
///
/// Zaslon never moves from one VPN to the other on its own while running: if the watched one drops, the list is
/// frozen until that same one is back, even when another VPN is up.
enum Vpn: String {
    case warp, happ

    var name: String { self == .warp ? "WARP" : "Happ" }

    /// "auto", "warp" or "happ": what the settings hold.
    static var chosen: String { UserDefaults.standard.string(forKey: "vpn").flatMap { Vpn(rawValue: $0)?.rawValue } ?? "auto" }

    /// The VPN in use. Settled at start and when the setting is changed, never in between: "auto" looks at what
    /// is installed (WARP if its `warp-cli` is there, otherwise Happ), and installing or removing a VPN while
    /// Zaslon runs must not move the watch.
    static var current: Vpn { settled.withLock { $0 } }
    private static let settled = OSAllocatedUnfairLock(initialState: pick(chosen, warpInstalled: warpInstalled))
    private static var warpInstalled: Bool { FileManager.default.isExecutableFile(atPath: "/usr/local/bin/warp-cli") }

    static func pick(_ chosen: String, warpInstalled: Bool) -> Vpn { Vpn(rawValue: chosen) ?? (warpInstalled ? .warp : .happ) }

    /// The setting was changed by hand. The caller freezes the list right after.
    static func choose(_ code: String) {
        UserDefaults.standard.set(code, forKey: "vpn")
        let now = pick(code, warpInstalled: warpInstalled)
        settled.withLock { $0 = now }
    }

    /// Is this VPN connected, and which tunnels are its own. Anything unclear counts as not connected.
    func state() -> (ok: Bool, nets: Set<String>) {
        guard self == .happ else {
            let ok = warpConnected()
            return (ok, ok ? tunnels() : [])
        }
        let nets = happTunnels()
        return (!nets.isEmpty, nets)
    }

    /// The tunnels a new connection may be pinned to, right now. The gate asks on the queue that carries its
    /// data, so this does not scan all processes: it takes the Happ processes the last scan found and asks the
    /// kernel afresh, for each, whether it is still a Happ process and which tunnels it holds this instant.
    /// A process the last scan did not know can only be missed (the connection is refused), never taken wrongly.
    static func tunnelsNow() -> Set<String> {
        guard current == .happ else { return tunnels() }
        let seen = happPids.withLock { $0 }
        if seen.at == .distantPast { return happTunnels() } // the first ask with no watch running (the test modes): one scan
        // The watch scans twice a second. Without a watch the scan is renewed from here, off this queue.
        if Date().timeIntervalSince(seen.at) > 0.6 { DispatchQueue.global(qos: .userInitiated).async { _ = happTunnels() } }
        return tunnelsHeld(byHapp: seen.pids)
    }
}

/// The tunnel interfaces whose control socket the process holds, as "utun6". Read from the kernel's table of the
/// process's open files; a process of another user (root) cannot be read and gives nothing.
func tunnelsHeld(by pid: pid_t) -> [String] {
    let step = MemoryLayout<proc_fdinfo>.stride
    let room = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard room > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(room) / step)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, room)
    var found: [String] = []
    for fd in fds.prefix(Int(max(got, 0)) / step) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_kind == SOCKINFO_KERN_CTL else { continue }
        var control = info.psi.soi_proto.pri_kern_ctl
        let kind = withUnsafeBytes(of: &control.kcsi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if kind == "com.apple.net.utun_control", control.kcsi_unit > 0 { found.append("utun\(control.kcsi_unit - 1)") } // unit 7 is utun6
    }
    return found
}

/// Whether the executable sits inside an app whose name carries `name`: ".../Happ.app/Contents/PlugIns/…".
func inApp(_ path: String, named name: String) -> Bool {
    path.split(separator: "/").first { $0.hasSuffix(".app") }?.localizedCaseInsensitiveContains(name) == true
}

private var happName: String { UserDefaults.standard.string(forKey: "vpnName") ?? "happ" }
private let happPids = OSAllocatedUnfairLock(initialState: (at: Date.distantPast, pids: [pid_t]()))

/// The tunnels, as "utun6/198.18.0.1", that these processes hold and that are up, counting only processes
/// that are Happ's at this instant (a process number can pass to another program).
private func tunnelsHeld(byHapp pids: [pid_t]) -> Set<String> {
    let held = Set(pids.filter { pid in
        var path = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &path, UInt32(path.count)) > 0 && inApp(String(cString: path), named: happName)
    }.flatMap { tunnelsHeld(by: $0) })
    return tunnels().filter { held.contains(String($0.prefix { $0 != "/" })) }
}

/// Happ's tunnels that are up right now; empty when Happ is not connected.
/// A tunnel is Happ's when a process of the Happ app holds it. No other tunnel counts, so WARP's is never taken
/// for Happ's. Takes a process scan (5–10 ms): not for the gate's queue, which uses `Vpn.tunnelsNow()`.
// ponytail: only Happ by default. `defaults write local.zaslon vpnName <name>` watches another client by its app's
// name; give such clients their own switch position when someone asks.
// ponytail: a build of Happ that keeps its tunnel in a root helper cannot be read and stays "not connected".
func happTunnels(_ procs: [Proc]? = nil) -> Set<String> {
    let seen = (at: Date(), pids: (procs ?? listProcs()).filter { inApp($0.path, named: happName) }.map(\.pid))
    happPids.withLock { $0 = seen }
    return tunnelsHeld(byHapp: seen.pids)
}

/// `Zaslon --vpn`: which VPN is watched and what Zaslon sees of it. For a first look on a new Mac.
func vpnReport() {
    let state = Vpn.current.state()
    print("setting: \(Vpn.chosen), watching: \(Vpn.current.name), connected: \(state.ok), its tunnels: \(state.nets.sorted().joined(separator: ", "))")
    print("all tunnels: \(tunnels().sorted().joined(separator: ", "))")
    // Every tunnel holder this user can read, so that a client under another name can be recognised.
    for p in listProcs() {
        let held = tunnelsHeld(by: p.pid)
        if !held.isEmpty { print("holds \(held.joined(separator: ", ")): \(p.origin.isEmpty ? p.path : p.origin)") }
    }
}
