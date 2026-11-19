import Foundation
import os

/// Which VPN Zaslon watches. WARP is asked through `warp-cli`, exactly as before this file existed. Happ (a client
/// for VLESS, Reality and the like; the protocol makes no difference here) is a VPN configuration that macOS
/// itself knows, so macOS is asked: is that configuration connected, and which tunnel interface is its own.
///
/// Zaslon never moves from one VPN to the other on its own while running: if the watched one drops, the list is
/// frozen until that same one is back, even when another VPN is up.
enum Vpn: String, CaseIterable {
    case warp, happ

    var name: String { self == .warp ? "WARP" : "Happ" }

    /// "auto", "warp" or "happ": what the settings hold.
    static var chosen: String { UserDefaults.standard.string(forKey: "vpn").flatMap { Vpn(rawValue: $0)?.rawValue } ?? "auto" }

    /// The VPN in use. "auto" looks at what is installed: WARP if its `warp-cli` is there, otherwise Happ.
    static var current: Vpn { pick(chosen, warpInstalled: FileManager.default.isExecutableFile(atPath: "/usr/local/bin/warp-cli")) }

    static func pick(_ chosen: String, warpInstalled: Bool) -> Vpn { Vpn(rawValue: chosen) ?? (warpInstalled ? .warp : .happ) }

    /// Is the VPN connected, and which tunnels are its own. Anything unclear counts as not connected.
    func state() -> (ok: Bool, nets: Set<String>) {
        guard self == .happ else {
            let ok = warpConnected()
            return (ok, ok ? tunnels() : [])
        }
        let nets = happTunnels()
        return (!nets.isEmpty, nets)
    }

    /// The tunnels a new connection may be pinned to, right now.
    static func tunnelsNow() -> Set<String> { current == .happ ? happTunnels() : tunnels() }
}

/// macOS's list of VPN configurations (`scutil --nc list`) → the id of the connected one whose line carries `name`.
///     * (Connected)      1B2C…-…  VPN (com.example.happ) "Happ"      [VPN:com.example.happ]
func parseVpnList(_ list: String, name: String) -> String? {
    for line in list.split(separator: "\n") where line.contains("(Connected)") && line.localizedCaseInsensitiveContains(name) {
        if let id = line.split(separator: " ").first(where: { $0.count == 36 && $0.filter({ $0 == "-" }).count == 4 }) { return String(id) }
    }
    return nil
}

/// The tunnel interface in `scutil --nc status <id>`: "InterfaceName : utun6".
func parseVpnInterface(_ status: String) -> String? {
    status.split(separator: "\n").compactMap { line -> String? in
        let words = line.split(separator: " ")
        return words.count == 3 && words[0] == "InterfaceName" && words[2].hasPrefix("utun") ? String(words[2]) : nil
    }.first
}

private func scutil(_ arguments: [String]) -> String {
    let (p, pipe) = (Process(), Pipe())
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
    p.arguments = arguments
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } } // a hung answer is no answer
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private let happSeen = OSAllocatedUnfairLock(initialState: (at: Date.distantPast, interface: String?.none, connected: false))

/// Happ's tunnels that are up right now, as "utun6/198.18.0.1"; empty when Happ is not connected.
///
/// macOS is asked at most every 0.4 s (the gate asks for every connection); the interfaces themselves are read
/// afresh every time, so a tunnel that has just gone is never returned.
// ponytail: if macOS does not name the interface, every tunnel with an IPv4 address counts, as with WARP. With
// WARP connected too, that could be WARP's tunnel. Tell them apart by the tunnel's owner if a build of Happ needs it.
// ponytail: only Happ by default. `defaults write local.zaslon vpnName <name>` watches another client that macOS
// lists under VPN; give such clients their own switch position when someone asks.
func happTunnels() -> Set<String> {
    let seen = happSeen.withLock { $0 }
    var (interface, connected) = (seen.interface, seen.connected)
    if Date().timeIntervalSince(seen.at) > 0.4 {
        let id = parseVpnList(scutil(["--nc", "list"]), name: UserDefaults.standard.string(forKey: "vpnName") ?? "happ")
        let fresh = (at: Date(), interface: id.flatMap { parseVpnInterface(scutil(["--nc", "status", $0])) }, connected: id != nil)
        happSeen.withLock { $0 = fresh }
        (interface, connected) = (fresh.interface, fresh.connected)
    }
    guard connected else { return [] }
    return tunnels().filter { interface == nil || $0.hasPrefix(interface! + "/") }
}

/// `Zaslon --vpn`: which VPN is watched and what Zaslon sees of it. For a first look on a new Mac.
func vpnReport() {
    let state = Vpn.current.state()
    print("setting: \(Vpn.chosen), watching: \(Vpn.current.name), connected: \(state.ok), its tunnels: \(state.nets.sorted().joined(separator: ", "))")
    print("all tunnels: \(tunnels().sorted().joined(separator: ", "))")
    if Vpn.current == .happ { print(scutil(["--nc", "list"])) }
}
