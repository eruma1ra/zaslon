import AppKit
import CryptoKit

/// A release as GitHub describes it: the version, where its disk image is, and the image's SHA-256.
struct Release: Equatable {
    var version: String
    var image: URL
    var sha256: String
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Updates Zaslon from the latest release on GitHub, for those who switched that on in the settings.
///
/// Once a day, and only while the VPN is up, it asks GitHub for the latest release. A newer one is downloaded,
/// checked and put in place of the running app, and Zaslon starts again from it. The list, the gate rules and the
/// journal live outside the app bundle and stay as they are.
///
/// There is no Apple Developer ID behind Zaslon, so the checks are these: the image must have the SHA-256 that
/// GitHub lists for it, and the app inside must be Zaslon, be the announced version and have an intact signature.
/// Whoever controls the GitHub repository controls the update: that is the trust this switch asks for.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let feed = "https://api.github.com/repos/eruma1ra/zaslon/releases/latest"
    /// Installed with Homebrew: the formula owns the app there, and `brew upgrade zaslon` updates it.
    static let brewed = Bundle.main.bundlePath.contains("/Cellar/")
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// `waiting(nil)`: a check is due but the VPN is down, so it is not known yet whether there is anything newer.
    enum Step: Equatable { case idle, waiting(String?), updating(String), failed(String) }

    @Published var on = UserDefaults.standard.bool(forKey: "autoUpdate")
    @Published var step = Step.idle
    /// The last check found nothing newer. Only then does the status say "the latest".
    @Published var latest = false
    private var found: Release?
    private var busy = false

    func choose(_ on: Bool) {
        self.on = on
        UserDefaults.standard.set(on, forKey: "autoUpdate")
        if on { check(force: true) } else { (step, latest, found) = (.idle, false, nil) }
    }

    /// Checks at start and then every ten minutes; GitHub itself is asked once a day, the rest only waits for the VPN.
    func watch() {
        check()
        RunLoop.main.add(Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.check() }, forMode: .common)
    }

    /// One pass: ask GitHub if it is time, and install what was found. Nothing goes out while the VPN is down.
    func check(force: Bool = false) {
        guard on, !Self.brewed, !busy else { return }
        let asked = UserDefaults.standard.object(forKey: "updateAsked") as? Date ?? .distantPast
        let (known, due) = (found, force || Date().timeIntervalSince(asked) > 86400)
        guard known != nil || due else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            var release = known
            let show = { (step: Step, latest: Bool) in
                DispatchQueue.main.async { (self.step, self.latest, self.found, self.busy) = (step, latest, release, false) }
            }
            guard warpConnected() else { return show(.waiting(known?.version), false) }
            do {
                if due {
                    release = try Self.latest(Self.fetch(URL(string: Self.feed)!))
                    UserDefaults.standard.set(Date(), forKey: "updateAsked")
                }
                guard let release, Self.newer(release.version, than: Self.version) else {
                    release = nil
                    return show(.idle, true)
                }
                DispatchQueue.main.async { self.step = .updating(release.version) }
                // Switched off while this was running: stop before anything is replaced.
                try Self.install(release, over: Bundle.main.bundleURL) { UserDefaults.standard.bool(forKey: "autoUpdate") }
                DispatchQueue.main.async {
                    UserDefaults.standard.set(["version": release.version, "at": Date()], forKey: "updated")
                    relaunchSoon()
                    NSApp.terminate(nil)
                }
            } catch {
                let off = !UserDefaults.standard.bool(forKey: "autoUpdate")
                show(off ? .idle : release.map { .failed($0.version) } ?? .idle, false)
            }
        }
    }

    /// What the settings row says under its title.
    var status: String {
        let version = t("Версия ", "Version ") + Self.version
        if Self.brewed { return version + t(". Обновление: brew upgrade zaslon", ". Update with: brew upgrade zaslon") }
        switch step {
        case .updating(let new): return t("Обновляю до ", "Updating to ") + new + "…"
        case .waiting(let new?): return t("Есть ", "Found ") + new + t(", жду VPN", ", waiting for the VPN")
        case .waiting(nil): return version + t(", проверю, когда вернётся VPN", ", will check when the VPN is back")
        case .failed(let new): return version + t(". Не удалось обновить до ", ". Could not update to ") + new
        case .idle:
            let done = UserDefaults.standard.dictionary(forKey: "updated")
            if done?["version"] as? String == Self.version, let at = done?["at"] as? Date {
                let when = DateFormatter()
                when.locale = Locale(identifier: t("ru_RU", "en_GB"))
                when.dateFormat = "d MMM HH:mm"
                return version + t(", обновлено ", ", updated ") + when.string(from: at)
            }
            return version + (on && latest ? t(", последняя", ", the latest") : "")
        }
    }

    // MARK: the steps, usable on any bundle (`Zaslon --update <app> [feed]` runs them for a test)

    /// "1.10.0" is newer than "1.9.3": compared number by number, not as text.
    static func newer(_ a: String, than b: String) -> Bool {
        let (x, y) = (a.split(separator: ".").map { Int($0) ?? 0 }, b.split(separator: ".").map { Int($0) ?? 0 })
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    /// Reads GitHub's "latest release" answer. A release without a disk image, or without its SHA-256, is no release.
    static func latest(_ json: Data) throws -> Release {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let tag = top["tag_name"] as? String,
              let assets = top["assets"] as? [[String: Any]] else { throw UpdateError("the feed is not a release") }
        for asset in assets {
            guard let name = asset["name"] as? String, name.hasSuffix(".dmg"), let link = (asset["browser_download_url"] as? String).flatMap(URL.init),
                  let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else { continue }
            return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, image: link, sha256: String(digest.dropFirst(7)))
        }
        throw UpdateError("the release has no disk image with a SHA-256")
    }

    @discardableResult static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        (process.standardOutput, process.standardError) = (FileHandle.nullDevice, FileHandle.nullDevice)
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Zaslon's own requests go through its tunnel proxy, so they are pinned to the VPN like everything behind the
    /// gate: if the VPN drops between the check and the request, the request fails instead of leaving another way.
    private static let session: URLSession = {
        let through = URLSessionConfiguration.ephemeral
        through.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(TunnelProxy.port)]
        through.timeoutIntervalForResource = 120
        return URLSession(configuration: through)
    }()

    /// Fetches a URL through the tunnel proxy and waits for it. A local file is simply read (tests).
    static func fetch(_ url: URL) throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        guard url.scheme == "https" else { throw UpdateError("only https is fetched") }
        var result: Result<Data, Error> = .failure(UpdateError("no answer"))
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result = .success(data) }
            else { result = .failure(error ?? UpdateError("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    /// Downloads the release, checks it and puts its app in place of `bundle`. Throws before anything is replaced
    /// if a check fails; the swap itself is one atomic step. `proceed` is asked once more right before the swap.
    static func install(_ release: Release, over bundle: URL, proceed: () -> Bool = { true }) throws {
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("zaslon-update-\(UUID().uuidString)")
        let (image, mount) = (work.appendingPathComponent("Zaslon.dmg"), work.appendingPathComponent("mount"))
        try files.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: work) }

        let data = try fetch(release.image)
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sum == release.sha256.lowercased() else { throw UpdateError("the download does not match its SHA-256") }
        try data.write(to: image)

        guard run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-mountpoint", mount.path]) == 0 else { throw UpdateError("the disk image does not open") }
        defer { run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        // Staged next to the installed app, so the swap stays on one volume.
        let staged = bundle.deletingLastPathComponent().appendingPathComponent(".Zaslon-update.app")
        try? files.removeItem(at: staged)
        do { try files.copyItem(at: mount.appendingPathComponent("Zaslon.app"), to: staged) } catch { throw UpdateError("cannot write next to the app: \(error.localizedDescription)") }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "local.zaslon", info?["CFBundleShortVersionString"] as? String == release.version,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) == 0 else {
            try? files.removeItem(at: staged)
            throw UpdateError("the app in the image is not Zaslon \(release.version) with an intact signature")
        }
        guard proceed() else {
            try? files.removeItem(at: staged)
            throw UpdateError("updates were switched off")
        }
        _ = try files.replaceItemAt(bundle, withItemAt: staged)
    }

    /// The whole update of one bundle, in the open, for `Zaslon --update <app> [feed]`. Returns the exit code.
    static func once(bundle: URL, feed: String) -> Int32 {
        do {
            let have = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String ?? "0"
            guard let source = URL(string: feed) else { throw UpdateError("the feed address is not a URL") }
            let release = try latest(fetch(source))
            print("installed \(have), latest \(release.version)")
            guard newer(release.version, than: have) else {
                print("nothing to do")
                return 0
            }
            try install(release, over: bundle)
            print("updated to \(release.version)")
            return 0
        } catch {
            print("update failed: \(error)")
            return 1
        }
    }
}
