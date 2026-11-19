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

    /// The tunnels a new connection may be pinned to, right now. Never waits: the gate asks on the queue that
    /// carries its data.
    static func tunnelsNow() -> Set<String> {
        guard current == .happ else { return tunnels() }
        let seen = happSeen.withLock { $0 }
        let age = Date().timeIntervalSince(seen.at)
        // The watch refreshes this twice a second. Without a watch (the test modes) it is refreshed from here.
        if age > 0.6 { DispatchQueue.global(qos: .userInitiated).async { _ = happTunnels() } }
        // ponytail: a tunnel name seen up to 2 s ago is trusted if that interface is still up. If another VPN took
        // the same name within those 2 s, a connection would be pinned to it; compare addresses too if that shows up.
        guard age < 2 else { return [] }
        return tunnels().filter { seen.names.contains(String($0.prefix { $0 != "/" })) }
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

private let happSeen = OSAllocatedUnfairLock(initialState: (at: Date.distantPast, names: Set<String>()))

/// Happ's tunnels that are up right now, as "utun6/198.18.0.1"; empty when Happ is not connected.
/// A tunnel is Happ's when a process of the Happ app holds it. No other tunnel counts, so WARP's is never taken
/// for Happ's. Takes a process scan (5–10 ms): not for the gate's queue, which reads `Vpn.tunnelsNow()`.
// ponytail: only Happ by default. `defaults write local.zaslon vpnName <name>` watches another client by its app's
// name; give such clients their own switch position when someone asks.
// ponytail: a build of Happ that keeps its tunnel in a root helper cannot be read and stays "not connected".
func happTunnels(_ procs: [Proc]? = nil) -> Set<String> {
    let name = UserDefaults.standard.string(forKey: "vpnName") ?? "happ"
    let held = Set((procs ?? listProcs()).filter { inApp($0.origin, named: name) || inApp($0.path, named: name) }.flatMap { tunnelsHeld(by: $0.pid) })
    let nets = tunnels().filter { held.contains(String($0.prefix { $0 != "/" })) }
    let seen = (at: Date(), names: Set(nets.map { String($0.prefix { $0 != "/" }) }))
    happSeen.withLock { $0 = seen }
    return nets
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
