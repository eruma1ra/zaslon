import Foundation
import Network

/// The only way out for the proxy and the gate: TCP connections pinned to the VPN tunnel interface.
///
/// A connection pinned to the tunnel never moves to Wi-Fi; when the tunnel is gone the connection fails, and so does
/// every new one. There is nothing to react to, so nothing can leave in the time a reaction would take.
final class Tunnel {
    static let shared = Tunnel()
    let queue = DispatchQueue(label: "zaslon.tunnel")
    var pinned: String? // an interface name given on the command line, for tests

    private let monitor = NWPathMonitor()
    private let lookups = DispatchQueue(label: "zaslon.dns", attributes: .concurrent)
    private var cache: [String: (address: String, until: Date)] = [:] // used on `queue` only

    private init() { monitor.start(queue: queue) }

    /// The VPN tunnel right now, asked afresh for every connection: the utun that is up and holds an IPv4 address
    /// (the system's own utuns have neither). nil when there is no such tunnel.
    var interface: NWInterface? {
        let names = pinned.map { [$0] } ?? Vpn.tunnelsNow().map { String($0.prefix { $0 != "/" }) }
        return monitor.currentPath.availableInterfaces.first { names.contains($0.name) }
    }

    /// Opens a connection through the tunnel and hands it over once, ready; nil when there is no tunnel, no address,
    /// or no route through the tunnel. Call on `queue`. Without a tunnel not even the DNS question is asked.
    func open(_ host: String, _ port: NWEndpoint.Port, then: @escaping (NWConnection?) -> Void) {
        guard let tunnel = interface else { return then(nil) }
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return connect(host, port, tunnel, then) }
        if let hit = cache[host], hit.until > Date() { return connect(hit.address, port, tunnel, then) }
        lookups.async {
            let address = realAddress(host)
            self.queue.async {
                guard let address else { return then(nil) }
                self.cache[host] = (address, Date().addingTimeInterval(60))
                self.connect(address, port, tunnel, then)
            }
        }
    }

    // ponytail: one address per name, no second try on another one. Add a loop if a service ever needs it.
    private func connect(_ address: String, _ port: NWEndpoint.Port, _ tunnel: NWInterface, _ then: @escaping (NWConnection?) -> Void) {
        let through = NWParameters.tcp
        through.requiredInterface = tunnel // the whole point: this connection can use the tunnel and nothing else
        let upstream = NWConnection(host: NWEndpoint.Host(address), port: port, using: through)
        var answered = false
        upstream.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if !answered { then(upstream) }
                answered = true
            case .waiting, .failed:
                // "waiting" means the tunnel cannot carry this right now. Do not wait for another way out: give up.
                // After the hand-over the cancel ends the pipes, and they close the program's side.
                upstream.cancel()
                if !answered { then(nil) }
                answered = true
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    func pipe(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { failed in
                    if failed != nil || done || error != nil {
                        from.cancel()
                        to.cancel()
                    } else {
                        self?.pipe(from, to)
                    }
                })
            } else {
                from.cancel()
                to.cancel()
            }
        }
    }
}

/// A name's real IPv4 address, asked from the system's main DNS servers (/etc/resolv.conf: WARP's own resolver while
/// the VPN is up). The usual lookup calls cannot be used here: they follow the gate's rule and answer 127.0.0.1.
func realAddress(_ host: String) -> String? {
    let lines = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8))?.split(separator: "\n") ?? []
    let servers: [String] = lines.compactMap { line in
        let words = line.split(separator: " ")
        return words.count >= 2 && words[0] == "nameserver" ? String(words[1]) : nil
    }
    let query = dnsQuery(host)
    for server in servers.prefix(2) {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { continue }
        defer { close(s) }
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        guard var to = ipv4(server, 53) else { continue }
        let ok = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, send(s, query, query.count, 0) == query.count else { continue }
        var reply = [UInt8](repeating: 0, count: 1500)
        let n = recv(s, &reply, reply.count, 0)
        guard n > 2, reply[0] == query[0], reply[1] == query[1] else { continue }
        // An answer that points back at this Mac would make the gate forward to itself.
        if let address = dnsAddresses(Array(reply[..<n])).first(where: { !$0.hasPrefix("127.") }) { return address }
    }
    return nil
}

func ipv4(_ address: String, _ port: UInt16) -> sockaddr_in? {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    return inet_pton(AF_INET, address, &a.sin_addr) == 1 ? a : nil
}

/// A DNS question for the name's IPv4 addresses.
func dnsQuery(_ host: String) -> [UInt8] {
    let labels = host.split(separator: ".").flatMap { [UInt8($0.utf8.count & 63)] + Array($0.utf8.prefix(63)) }
    return [UInt8.random(in: 0...255), UInt8.random(in: 0...255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0] + labels + [0, 0, 1, 0, 1]
}

/// The IPv4 addresses in a DNS reply.
func dnsAddresses(_ m: [UInt8]) -> [String] {
    guard m.count > 12 else { return [] }
    var p = 12
    func skipName() {
        while p < m.count {
            let size = Int(m[p])
            if size == 0 { p += 1; return }
            if size >= 0xC0 { p += 2; return } // a pointer to a name written earlier
            p += 1 + size
        }
    }
    for _ in 0..<(Int(m[4]) << 8 | Int(m[5])) { skipName(); p += 4 }
    var found: [String] = []
    for _ in 0..<(Int(m[6]) << 8 | Int(m[7])) {
        skipName()
        guard p + 10 <= m.count else { break }
        let (kind, size) = (Int(m[p]) << 8 | Int(m[p + 1]), Int(m[p + 8]) << 8 | Int(m[p + 9]))
        p += 10
        guard p + size <= m.count else { break }
        if kind == 1, size == 4 { found.append(m[p..<(p + 4)].map { String($0) }.joined(separator: ".")) }
        p += size
    }
    return found
}

/// An HTTP CONNECT proxy on 127.0.0.1 whose outgoing connections are pinned to the VPN tunnel interface.
///
/// A program that sends everything through it cannot leak past the VPN. The gate starts ChatGPT and Claude with it
/// (see Gate.open); command-line tools can use HTTPS_PROXY; Claude Desktop also has an `egressProxyUrl` setting.
///
/// ponytail: CONNECT only, which is all HTTPS needs; a plain http:// request gets 405. Add forwarding if something needs it.
final class TunnelProxy: ObservableObject {
    static let shared = TunnelProxy()
    static let port: UInt16 = 47800
    static var url: String { "http://127.0.0.1:\(port)" }

    @Published var listening = false

    private let tunnel = Tunnel.shared
    private var listener: NWListener?

    /// Starts listening. `interface` pins the proxy to that interface instead of the VPN tunnel (tests only).
    func start(port: UInt16 = TunnelProxy.port, interface: String? = nil) {
        if let interface { tunnel.pinned = interface }
        let local = NWParameters.tcp
        local.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) // this Mac only
        local.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: local) else { return }
        listener.stateUpdateHandler = { [weak self] state in
            let up = { if case .ready = state { return true } else { return false } }()
            DispatchQueue.main.async { self?.listening = up }
        }
        listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
        listener.start(queue: tunnel.queue)
        self.listener = listener
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: tunnel.queue)
        readHead(client, Data())
    }

    /// Reads up to the blank line that ends the CONNECT request.
    private func readHead(_ client: NWConnection, _ soFar: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self, let data, error == nil else { return client.cancel() }
            let head = soFar + data
            guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                return done || head.count > 16384 ? client.cancel() : self.readHead(client, head)
            }
            let words = String(decoding: head[..<end.lowerBound], as: UTF8.self).prefix { $0 != "\r" }.split(separator: " ")
            guard words.count >= 2, words[0] == "CONNECT", let target = Self.split(String(words[1])) else {
                return self.refuse(client, "405 CONNECT only")
            }
            let early = head[end.upperBound...]
            self.tunnel.open(target.host, target.port) { upstream in
                guard let upstream else { return self.refuse(client, "502 No route through the VPN tunnel") }
                client.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                if !early.isEmpty { upstream.send(content: early, completion: .contentProcessed { _ in }) }
                self.tunnel.pipe(client, upstream)
                self.tunnel.pipe(upstream, client)
            }
        }
    }

    /// "host:443" or "[2606:4700::1]:443" → host and port.
    static func split(_ target: String) -> (host: String, port: NWEndpoint.Port)? {
        guard let colon = target.lastIndex(of: ":"), let port = NWEndpoint.Port(String(target[target.index(after: colon)...])) else { return nil }
        let host = target[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }

    private func refuse(_ client: NWConnection, _ status: String) {
        client.send(content: Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() })
    }
}
