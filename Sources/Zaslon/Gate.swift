import AppKit
import Network

/// The gate: the servers of ChatGPT and Claude can be reached from this Mac only through the VPN tunnel.
///
/// 1. A system DNS rule (/etc/resolver/<domain>, set once with the admin password) sends every program's question
///    about these domains to the small DNS answerer here, and it always says "127.0.0.1".
/// 2. So every program, helpers that ignore proxy settings included, opens its TLS connection to this Mac, port 443.
///    The forwarder here reads the server name from the first packet and passes the bytes on through a connection
///    pinned to the tunnel. TLS stays end to end; nothing is decrypted.
/// No tunnel, or no Zaslon: the connection fails. There is no path that leads past the VPN, so there is no window.
///
/// Everything else such an app talks to (Google, GitHub, MCP servers) is covered by starting the app through the
/// tunnel proxy: `open`.
final class Gate: ObservableObject {
    static let shared = Gate()
    static let dnsPort: UInt16 = 5354
    static let services: [(app: String, domains: [String])] = [
        ("/Applications/ChatGPT.app", ["chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]),
        ("/Applications/Claude.app", ["anthropic.com", "claude.ai", "claude.com", "claudeusercontent.com"]),
    ]
    static var domains: [String] { services.flatMap(\.domains) }
    /// What a Chromium-based app needs on its command line to send its own traffic through the proxy.
    static var flag: String { "--proxy-server=\(TunnelProxy.url)" }

    @Published var listening = false
    /// The service apps whose system DNS rule is in place.
    @Published var ruled: Set<String> = []
    /// The service apps that right now hold a connection which really leaves outside the VPN tunnel.
    @Published var past: Set<String> = []

    private let tunnel = Tunnel.shared
    private var listener: NWListener?
    private var dns: DispatchSourceRead?

    /// Starts the DNS answerer and the forwarder. Other ports are for tests.
    func start(port: UInt16 = 443, dnsPort: UInt16 = Gate.dnsPort) {
        tunnel.queue.async {
            self.answer(dnsPort)
            self.forward(port)
        }
    }

    // MARK: forwarder

    private func forward(_ port: UInt16) {
        // Without root a low port can be taken on "any address" only, so the listener is tied to the loopback
        // interface instead (measured: 127.0.0.1 as the local address is refused, this is accepted).
        let local = NWParameters.tcp
        local.requiredInterfaceType = .loopback
        local.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: local, on: NWEndpoint.Port(rawValue: port)!) else { return retry { self.forward(port) } }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            var up = false
            switch state {
            case .ready: up = true
            case .failed: // the port is still held by an older copy
                listener.cancel()
                self.retry { self.forward(port) }
            default: break
            }
            DispatchQueue.main.async { self.listening = up }
        }
        listener.newConnectionHandler = { [weak self] client in
            guard let self, case let .hostPort(host, _) = client.endpoint, Self.local(host) else { return client.cancel() }
            client.start(queue: self.tunnel.queue)
            self.readHello(client, [])
        }
        listener.start(queue: tunnel.queue)
        self.listener = listener
    }

    private func retry(_ work: @escaping () -> Void) { tunnel.queue.asyncAfter(deadline: .now() + 0.5, execute: work) }

    static func local(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        default: return false
        }
    }

    /// Reads the whole first TLS record, takes the server name from it and connects that name through the tunnel.
    private func readHello(_ client: NWConnection, _ soFar: [UInt8]) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self, let data, error == nil else { return client.cancel() }
            let hello = soFar + data
            let whole = hello.count >= 5 ? 5 + (Int(hello[3]) << 8 | Int(hello[4])) : Int.max
            if hello.count < whole, hello.count < 16384, !done { return self.readHello(client, hello) }
            // Only the listed services: this is not a forwarder to anywhere.
            guard let name = serverName(hello), Self.covers(name) else { return client.cancel() }
            self.tunnel.open(name, 443) { upstream in
                guard let upstream else {
                    // Only a refusal for lack of a tunnel is a fact about an outage; a failed lookup or route is not.
                    if self.tunnel.interface == nil { DispatchQueue.main.async { Journal.shared.refuse() } }
                    return client.cancel()
                }
                upstream.send(content: Data(hello), completion: .contentProcessed { _ in })
                self.tunnel.pipe(client, upstream)
                self.tunnel.pipe(upstream, client)
            }
        }
    }

    static func covers(_ name: String) -> Bool { domains.contains { name == $0 || name.hasSuffix("." + $0) } }

    // MARK: DNS answerer

    private func answer(_ port: UInt16) {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var me = ipv4("127.0.0.1", port)! // this Mac only
        let bound = withUnsafePointer(to: &me) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else {
            close(s)
            return retry { self.answer(port) }
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: s, queue: tunnel.queue)
        source.setEventHandler {
            var packet = [UInt8](repeating: 0, count: 1500)
            var from = sockaddr_storage()
            var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(s, &packet, packet.count, 0, $0, &size) } }
            guard n > 0, let reply = dnsAnswer(Array(packet[..<n])) else { return }
            _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, reply, reply.count, 0, $0, size) } }
        }
        source.resume()
        dns = source
    }

    // MARK: the system rule and the apps (main thread)

    static func rulesInPlace() -> Set<String> {
        Set(services.filter { service in
            service.domains.allSatisfy { ours((try? String(contentsOfFile: "/etc/resolver/" + $0, encoding: .utf8)) ?? "") }
        }.map(\.app))
    }

    /// Reads, off the main thread, which rules are in place and which service apps really send something outside
    /// the tunnel: a fact taken from their open connections, not from how they were started.
    func look() {
        DispatchQueue.global(qos: .utility).async {
            let ruled = Self.rulesInPlace()
            let (procs, inside) = (listProcs(), tunnelAddresses())
            let past = Set(Self.services.map(\.app).filter { app in
                tree(of: Entry(name: "", matches: [app]), in: procs).contains { leavesOutside($0, inside) }
            })
            DispatchQueue.main.async {
                if self.ruled != ruled { self.ruled = ruled }
                if self.past != past { self.past = past }
            }
        }
    }

    func watch() {
        look()
        RunLoop.main.add(Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.look() }, forMode: .common)
    }

    static func ours(_ rule: String) -> Bool { rule.contains("nameserver 127.0.0.1") && rule.contains("port \(dnsPort)") }

    /// The shell lines that write or remove the rule files. Removing touches only files that hold our rule.
    static func ruleShell(_ on: Bool, _ domains: [String], folder: String = "/etc/resolver") -> String {
        let names = domains.joined(separator: " ")
        return on
            ? "mkdir -p \(folder) && for d in \(names); do printf 'nameserver 127.0.0.1\\nport \(dnsPort)\\n' > \(folder)/$d; done"
            : "for d in \(names); do grep -qs 'port \(dnsPort)' \(folder)/$d && rm -f \(folder)/$d; done; true"
    }

    /// Runs shell lines through the system's own "do shell script", which can ask for the admin password itself.
    static func run(_ shell: String, admin: Bool, then: @escaping () -> Void = {}) -> Process {
        let quoted = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let ask = Process()
        ask.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        ask.arguments = ["-e", "do shell script \"\(quoted)\"" + (admin ? " with prompt \"\(t("Zaslon меняет правило DNS для ворот VPN.", "Zaslon is changing the DNS rule of the VPN gate."))\" with administrator privileges" : "")]
        ask.terminationHandler = { _ in then() }
        try? ask.run()
        return ask
    }

    /// Writes or removes one service's DNS rule; the system asks for the admin password. `then` hears whether the
    /// rule is now as asked: a refused password leaves it as it was.
    func setRules(_ on: Bool, app: String, then: @escaping (Bool) -> Void = { _ in }) {
        let names = Self.services.first { $0.app == app }?.domains ?? []
        _ = Self.run(Self.ruleShell(on, names) + "; dscacheutil -flushcache; killall -HUP mDNSResponder", admin: true) {
            DispatchQueue.main.async {
                self.ruled = Self.rulesInPlace()
                then(self.ruled.contains(app) == on)
            }
        }
    }

    /// Starts the app so that everything it sends goes through the tunnel proxy. A running copy is asked to quit
    /// first; if it does not (unsaved work), it is left alone.
    func open(_ app: String) {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app }
        running.forEach { $0.terminate() }
        let how = NSWorkspace.OpenConfiguration()
        how.arguments = [Self.flag]
        var env = ["NO_PROXY": "localhost,127.0.0.1,::1", "no_proxy": "localhost,127.0.0.1,::1"]
        for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] { (env[key], env[key.lowercased()]) = (TunnelProxy.url, TunnelProxy.url) }
        how.environment = env
        func go(_ tries: Int) {
            guard running.allSatisfy(\.isTerminated) else {
                if tries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go(tries - 1) } }
                return
            }
            // A moment for the app's helpers to leave, then the launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app), configuration: how) { _, _ in }
            }
        }
        go(40)
    }
}

/// The process's launch area as the kernel keeps it: path, arguments, environment.
func launchArea(_ pid: pid_t) -> Data {
    var (mib, size) = ([CTL_KERN, KERN_PROCARGS2, pid], 1 << 16)
    var area = [UInt8](repeating: 0, count: size)
    return sysctl(&mib, 3, &area, &size, nil, 0) == 0 ? Data(area.prefix(size)) : Data()
}

/// The server name (SNI) from the first bytes of a TLS connection; nil unless it is a ClientHello that carries one.
func serverName(_ h: [UInt8]) -> String? {
    func pair(_ i: Int) -> Int? { i >= 0 && i + 2 <= h.count ? Int(h[i]) << 8 | Int(h[i + 1]) : nil }
    guard h.count > 43, h[0] == 0x16 else { return nil }
    var p = 43 // record header 5, handshake header 4, version 2, random 32
    p += 1 + Int(h[p]) // session id
    guard let suites = pair(p) else { return nil }
    p += 2 + suites
    guard p < h.count else { return nil }
    p += 1 + Int(h[p]) // compression methods
    guard let total = pair(p) else { return nil }
    p += 2
    let end = min(p + total, h.count)
    while let kind = pair(p), let size = pair(p + 2), p + 4 + size <= end {
        if kind == 0, let n = pair(p + 7), p + 9 + n <= end { return String(decoding: h[(p + 9)..<(p + 9 + n)], as: UTF8.self) }
        p += 4 + size
    }
    return nil
}

/// The gate's reply to a DNS question: "it is at 127.0.0.1" for an IPv4 question, "no such record" for any other.
func dnsAnswer(_ q: [UInt8]) -> [UInt8]? {
    var end = 12
    while end < q.count, q[end] != 0 { end += 1 + Int(q[end]) }
    guard q.count >= end + 5 else { return nil }
    let question = Array(q[12..<(end + 5)])
    let address = question[question.count - 4] == 0 && question[question.count - 3] == 1
    let head: [UInt8] = [q[0], q[1], 0x81, 0x80, 0, 1, 0, address ? 1 : 0, 0, 0, 0, 0]
    return head + question + (address ? [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4, 127, 0, 0, 1] : [])
}

/// Every address this Mac holds on its VPN tunnels. A connection that starts from one of them is inside the VPN.
func tunnelAddresses() -> Set<String> {
    let names = Set(tunnels().map { String($0.prefix { $0 != "/" }) })
    var (found, head) = (Set<String>(), UnsafeMutablePointer<ifaddrs>?.none)
    guard getifaddrs(&head) == 0 else { return found }
    defer { freeifaddrs(head) }
    var next = head
    while let item = next {
        next = item.pointee.ifa_next
        guard names.contains(String(cString: item.pointee.ifa_name)), let address = item.pointee.ifa_addr,
              [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            found.insert(String(String(cString: host).prefix { $0 != "%" }))
        }
    }
    return found
}

/// Whether a connection with these two ends leaves this Mac outside the VPN: it goes to a public address and does
/// not start from a tunnel address. Loopback and the local network are not the internet.
func outside(local: String, remote: String, tunnel: Set<String>) -> Bool {
    if tunnel.contains(local) { return false }
    if let a = IPv4Address(remote) {
        let b = [UInt8](a.rawValue)
        let near = b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224 || (b[0] == 172 && b[1] & 0xF0 == 16)
            || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] & 0xC0 == 64)
        return !near
    }
    guard let a = IPv6Address(remote) else { return false }
    let b = [UInt8](a.rawValue)
    return !(a.isLoopback || a.isAny || b[0] == 0xFF || b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80))
}

/// Both ends of every connected internet socket the process holds, read from the kernel's table of its open files.
func connections(_ pid: pid_t) -> [(local: String, remote: String)] {
    let step = MemoryLayout<proc_fdinfo>.stride
    let room = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard room > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(room) / step)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, room)
    var found: [(String, String)] = []
    for fd in fds.prefix(Int(max(got, 0)) / step) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
        let s = info.psi
        let tcp = s.soi_kind == SOCKINFO_TCP
        guard tcp || s.soi_kind == SOCKINFO_IN else { continue }
        var ends = tcp ? s.soi_proto.pri_tcp.tcpsi_ini : s.soi_proto.pri_in
        guard ends.insi_fport != 0 else { continue } // not connected: a listener, or a socket not yet used
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        func name(_ address: UnsafeMutableRawPointer, _ v4: Bool) -> String {
            inet_ntop(v4 ? AF_INET : AF_INET6, v4 ? address + 12 : address, &text, socklen_t(text.count)) // IPv4 sits in the last 4 of the 16 bytes
            // An IPv4 connection on an IPv6 socket reads as "::1.2.3.4" or "::ffff:1.2.3.4": keep the IPv4 part.
            let read = String(cString: text)
            return read.contains(".") ? String(read.split(separator: ":").last ?? "") : read
        }
        let v4 = ends.insi_vflag & UInt8(INI_IPV4) != 0
        let local = withUnsafeMutablePointer(to: &ends.insi_laddr) { name(UnsafeMutableRawPointer($0), v4) }
        let remote = withUnsafeMutablePointer(to: &ends.insi_faddr) { name(UnsafeMutableRawPointer($0), v4) }
        found.append((local, remote))
    }
    return found
}

/// Whether the process holds an internet connection that leaves outside the tunnel. A socket still without its own
/// address has sent nothing yet.
func leavesOutside(_ pid: pid_t, _ tunnel: Set<String>) -> Bool {
    connections(pid).contains { $0.local != "0.0.0.0" && $0.local != "::" && outside(local: $0.local, remote: $0.remote, tunnel: tunnel) }
}
