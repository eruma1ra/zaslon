import AppKit

/// Tells the user when a newer Zaslon is out. It does not install anything.
///
/// With "Check for updates" switched on, Zaslon asks once a day, and only while the VPN is up, for a small file
/// attached to the latest release. If the version in it is newer than the running one, the settings say so and
/// offer the release page. Installing stays the user's step (the disk image, or `brew upgrade zaslon`).
///
/// Why not install by itself: Zaslon has no Apple Developer ID, and every way of replacing the app under its own
/// feet was tried and dropped. A restart leaves seconds without a watch over the VPN; swapping the app on disk
/// can leave the launch agent unable to start it at the next login. A kill switch that might not come back is
/// worse than one that asks for a click.
final class Updater: ObservableObject {
    static let shared = Updater()
    /// A small file attached to every release; this address always leads to the latest one. A plain download, so
    /// GitHub's API limit (60 questions an hour for one address, and a VPN shares its address) does not apply.
    static let feed = URL(string: "https://github.com/eruma1ra/zaslon/releases/latest/download/update.json")!
    static let page = URL(string: "https://github.com/eruma1ra/zaslon/releases/latest")!
    /// Installed with Homebrew: `brew upgrade zaslon` is how it is updated there.
    static let brewed = Bundle.main.bundlePath.contains("/Cellar/")
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    @Published var on = UserDefaults.standard.bool(forKey: "checkUpdates")
    /// A version newer than this one that the last check found.
    @Published var newer: String?
    /// The last check found nothing newer. Only then does the status say "the latest".
    @Published var latest = false
    private var busy = false

    func choose(_ on: Bool) {
        self.on = on
        UserDefaults.standard.set(on, forKey: "checkUpdates")
        if on { check(force: true) } else { (newer, latest) = (nil, false) }
    }

    /// Looks at start and then every ten minutes whether a day has passed since the last question.
    func watch() {
        check()
        RunLoop.main.add(Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.check() }, forMode: .common)
    }

    /// Asks for the latest version if a day has passed (or `force`). Nothing goes out while the VPN is down, and
    /// the day starts over with every question, answered or not.
    func check(force: Bool = false) {
        let asked = UserDefaults.standard.object(forKey: "updateAsked") as? Date ?? .distantPast
        guard on, !busy, force || Date().timeIntervalSince(asked) > 86400 else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            var found: String?
            if warpConnected() {
                UserDefaults.standard.set(Date(), forKey: "updateAsked")
                found = try? Self.described(Self.fetch(Self.feed))
            }
            DispatchQueue.main.async {
                self.busy = false
                guard self.on, let found else { return } // switched off meanwhile, or no answer: nothing changes
                let isNewer = Self.newer(found, than: Self.version)
                (self.newer, self.latest) = (isNewer ? found : nil, !isNewer)
            }
        }
    }

    /// What the settings row says under its title.
    var status: String {
        let version = t("Версия ", "Version ") + Self.version
        guard let newer else { return version + (on && latest ? t(", последняя", ", the latest") : "") }
        return version + t(". Вышла ", ". Version ") + newer + (Self.brewed ? t(": brew upgrade zaslon", " is out: brew upgrade zaslon") : t("", " is out"))
    }

    /// "1.10.0" is newer than "1.9.3": compared number by number, not as text.
    static func newer(_ a: String, than b: String) -> Bool {
        let (x, y) = (a.split(separator: ".").map { Int($0) ?? 0 }, b.split(separator: ".").map { Int($0) ?? 0 })
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    /// The version named in a release's `update.json`: {"version": "1.2.0", …}. Digits and dots only.
    static func described(_ json: Data) throws -> String {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let version = top["version"] as? String,
              !version.isEmpty, version.count <= 20, version.allSatisfy({ $0.isNumber || $0 == "." }) else { throw CocoaError(.fileReadCorruptFile) }
        return version
    }

    /// Fetches a small https file through Zaslon's own tunnel proxy, so the request is pinned to the VPN like
    /// everything behind the gate. If the proxy is not listening, nothing is sent at all.
    static func fetch(_ url: URL, port: UInt16 = TunnelProxy.port) throws -> Data {
        guard url.scheme == "https", TunnelProxy.shared.ready else { throw CocoaError(.fileReadNoPermission) }
        let through = URLSessionConfiguration.ephemeral
        through.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(port)]
        through.timeoutIntervalForResource = 30
        let session = URLSession(configuration: through)
        defer { session.invalidateAndCancel() }
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, _ in
            if let data, data.count < 4096, (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        done.wait()
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }
}
