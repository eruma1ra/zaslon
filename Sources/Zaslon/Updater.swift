import AppKit
import CryptoKit

/// A release as its `update.json` describes it: the version, where its disk image is, and the image's SHA-256.
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
/// Two halves, and neither touches the watch over the VPN:
/// 1. While Zaslon runs: once a day, and only while the VPN is up, it asks for the latest release. A newer one is
///    downloaded, checked and set aside in Zaslon's own folder. Nothing else changes.
/// 2. When Zaslon quits (Quit, logout, shutdown): a version set aside takes the app's place. Zaslon is closing
///    anyway, so nothing is interrupted, and the next start is simply the new version.
/// Zaslon never restarts itself for an update: a restart is seconds without a watch, and no update is worth that.
/// The list, the gate rules and the journal live outside the app bundle and stay as they are.
///
/// There is no Apple Developer ID behind Zaslon, so the checks are these: the image must have the SHA-256 that
/// the release states for it, and the app inside must be Zaslon, be the announced version and have an intact
/// signature. Whoever controls the GitHub repository controls the update: that is the trust this switch asks for.
final class Updater: ObservableObject {
    static let shared = Updater()
    /// A small file attached to every release; this address always leads to the latest one. A plain download, so
    /// GitHub's API limit (60 questions an hour for one address, and a VPN shares its address) does not apply.
    static let feed = "https://github.com/eruma1ra/zaslon/releases/latest/download/update.json"
    /// Installed with Homebrew: the formula owns the app there, and `brew upgrade zaslon` updates it.
    static let brewed = Bundle.main.bundlePath.contains("/Cellar/")
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// Where a downloaded and checked version waits until Zaslon quits.
    static let shelf = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Zaslon/update")

    /// `waiting(nil)`: a check is due but the VPN is down, so it is not known yet whether there is anything newer.
    enum Step: Equatable { case idle, waiting(String?), downloading(String), ready(String), failed(String) }

    @Published var on = UserDefaults.standard.bool(forKey: "autoUpdate")
    @Published var step = Step.idle
    /// The last check found nothing newer. Only then does the status say "the latest".
    @Published var latest = false
    private var found: Release?
    private var busy = false

    func choose(_ on: Bool) {
        self.on = on
        UserDefaults.standard.set(on, forKey: "autoUpdate")
        if on { return check(force: true) }
        (step, latest, found) = (.idle, false, nil)
        try? FileManager.default.removeItem(at: Self.shelf) // switched off: a version set aside is not wanted either
    }

    /// Checks at start and then every ten minutes; the release is asked for once a day, the rest only waits for the VPN.
    func watch() {
        // Off the main thread: checking a signature takes a moment, and the main thread is where the guard acts.
        DispatchQueue.global(qos: .utility).async {
            Self.sweep()
            let waiting = Self.waiting()
            DispatchQueue.main.async { if self.on, let waiting, self.step == .idle { self.step = .ready(waiting) } }
        }
        check()
        RunLoop.main.add(Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.check() }, forMode: .common)
    }

    /// One pass: ask for the latest release if it is time, and set aside what is newer. Nothing goes out while the
    /// VPN is down.
    func check(force: Bool = false) {
        guard on, !Self.brewed, !busy else { return }
        let asked = UserDefaults.standard.object(forKey: "updateAsked") as? Date ?? .distantPast
        let (known, due) = (found, force || Date().timeIntervalSince(asked) > 86400)
        guard known != nil || due else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            var release = known
            let show = { (step: Step, latest: Bool) in
                let waiting = Self.waiting() // here, not on the main thread: it checks a signature
                DispatchQueue.main.async {
                    self.busy = false
                    // Switched off meanwhile: the result is dropped, and so is anything this pass set aside.
                    guard self.on else {
                        try? FileManager.default.removeItem(at: Self.shelf)
                        return
                    }
                    (self.step, self.latest, self.found) = (step, latest, release)
                    // Whatever this pass ran into, a version that is set aside is still there, and the row says so.
                    if let waiting { self.step = .ready(waiting) }
                }
            }
            guard warpConnected() else { return show(.waiting(known?.version), false) }
            do {
                if due {
                    release = try Self.latest(Self.fetch(URL(string: Self.feed)!), from: URL(string: Self.feed)!)
                    UserDefaults.standard.set(Date(), forKey: "updateAsked")
                }
                guard let wanted = release, Self.newer(wanted.version, than: Self.version) else {
                    release = nil
                    return show(.idle, true)
                }
                if Self.staged(in: Self.shelf) != wanted.version {
                    DispatchQueue.main.async { self.step = .downloading(wanted.version) }
                    try Self.stage(wanted, in: Self.shelf)
                }
                release = nil // set aside: nothing more to fetch for it
                show(.ready(wanted.version), false)
            } catch {
                show(release.map { .failed($0.version) } ?? .idle, false)
            }
        }
    }

    /// What the settings row says under its title.
    var status: String {
        let version = t("Версия ", "Version ") + Self.version
        if Self.brewed { return version + t(". Обновление: brew upgrade zaslon", ". Update with: brew upgrade zaslon") }
        switch step {
        case .downloading(let new): return t("Скачиваю ", "Downloading ") + new + "…"
        case .ready(let new): return new + t(" скачана. Включится после перезапуска Zaslon", " is downloaded. It takes effect after Zaslon is restarted")
        case .waiting(let new?): return t("Есть ", "Found ") + new + t(", жду VPN", ", waiting for the VPN")
        case .waiting(nil): return version + t(", проверю, когда вернётся VPN", ", will check when the VPN is back")
        case .failed(let new): return version + t(". Не удалось скачать ", ". Could not download ") + new
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

    /// Called when Zaslon quits: puts a version set aside earlier in place of the app. Not under Homebrew, and
    /// not if updates were switched off since.
    static func applyAtQuit() {
        guard !brewed, UserDefaults.standard.bool(forKey: "autoUpdate"), let new = try? apply(from: shelf, over: Bundle.main.bundleURL) else { return }
        UserDefaults.standard.set(["version": new, "at": Date()], forKey: "updated")
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

    /// Reads the release's own small file, `update.json`: {"version": "1.2.0", "image": "<url of the disk image>",
    /// "sha256": "<of that image>"}. The image must be served over https from the host the file came from (a local
    /// file may name a local image: tests).
    static func latest(_ json: Data, from feed: URL) throws -> Release {
        guard let top = try? JSONSerialization.jsonObject(with: json) as? [String: Any], let version = top["version"] as? String,
              let image = (top["image"] as? String).flatMap(URL.init), let sum = top["sha256"] as? String, sum.count == 64 else { throw UpdateError("the feed is not a release description") }
        guard feed.isFileURL ? image.isFileURL : image.scheme == "https" && image.host == feed.host else { throw UpdateError("the disk image is not on the feed's host") }
        return Release(version: version, image: image, sha256: sum)
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

    static var proxyPort = TunnelProxy.port // `--update` runs its own proxy on another port
    /// Zaslon's own requests go through its tunnel proxy, so they are pinned to the VPN like everything behind the
    /// gate: if the VPN drops between the check and the request, the request fails instead of leaving another way.
    private static let session: URLSession = {
        let through = URLSessionConfiguration.ephemeral
        through.connectionProxyDictionary = ["HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": Int(proxyPort)]
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

    /// Whether the app at `app` is Zaslon with an intact signature; its version if so.
    static func sound(_ app: URL) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == "local.zaslon", let version = info?["CFBundleShortVersionString"] as? String,
              run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { return nil }
        return version
    }

    /// The version set aside in `shelf`, if there is a sound one.
    static func staged(in shelf: URL) -> String? { sound(shelf.appendingPathComponent("Zaslon.app")) }

    /// The version that waits on Zaslon's own shelf and is newer than the running one. Runs codesign: not for the
    /// main thread.
    static func waiting() -> String? { staged(in: shelf).flatMap { newer($0, than: version) ? $0 : nil } }

    /// Clears what a download left behind if Zaslon quit or died in the middle of one: a mounted image and its
    /// folder in the temporary directory, and a half-made copy beside the shelf.
    static func sweep() {
        let files = FileManager.default
        for (folder, prefix) in [(files.temporaryDirectory, "zaslon-update-"), (shelf.deletingLastPathComponent(), "update-incoming-")] {
            for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
                let left = folder.appendingPathComponent(name)
                run("/usr/bin/hdiutil", ["detach", left.appendingPathComponent("mount").path, "-force"])
                try? files.removeItem(at: left)
            }
        }
    }

    /// Downloads the release, checks it and sets its app aside in `shelf`, replacing whatever waited there. If a
    /// check fails it throws and the shelf stays as it was. The installed app is not touched.
    static func stage(_ release: Release, in shelf: URL) throws {
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

        // Copied and checked under another name beside the shelf, and only then given the shelf's name in one
        // step: a quit at any moment finds either a fully checked version there, or the previous state.
        let incoming = shelf.deletingLastPathComponent().appendingPathComponent("update-incoming-\(UUID().uuidString)")
        defer { try? files.removeItem(at: incoming) }
        try files.createDirectory(at: incoming, withIntermediateDirectories: true)
        let app = incoming.appendingPathComponent("Zaslon.app")
        try files.copyItem(at: mount.appendingPathComponent("Zaslon.app"), to: app)
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard sound(app) == release.version else { throw UpdateError("the app in the image is not Zaslon \(release.version) with an intact signature") }
        if files.fileExists(atPath: shelf.path) {
            _ = try files.replaceItemAt(shelf, withItemAt: incoming) // one step: the older one is not lost if this fails
        } else {
            try files.moveItem(at: incoming, to: shelf)
        }
    }

    /// Puts the version set aside in `shelf` in place of `bundle`, if it is sound and newer, and empties the shelf.
    /// Returns the new version, or nil if there was nothing to do. One step: afterwards the app is the new one,
    /// or it is untouched.
    static func apply(from shelf: URL, over bundle: URL) throws -> String? {
        let files = FileManager.default
        guard files.fileExists(atPath: shelf.path) else { return nil }
        defer { try? files.removeItem(at: shelf) }
        let have = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String ?? "0"
        guard let new = staged(in: shelf), newer(new, than: have) else { return nil }
        _ = try files.replaceItemAt(bundle, withItemAt: shelf.appendingPathComponent("Zaslon.app"))
        return new
    }

    /// The whole update of one bundle, in the open, for `Zaslon --update <app> [feed]`. Returns the exit code.
    static func once(bundle: URL, feed: String) -> Int32 {
        let shelf = FileManager.default.temporaryDirectory.appendingPathComponent("zaslon-shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: shelf) }
        do {
            let have = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String ?? "0"
            guard let source = URL(string: feed) else { throw UpdateError("the feed address is not a URL") }
            let release = try latest(fetch(source), from: source)
            print("installed \(have), latest \(release.version)")
            guard newer(release.version, than: have) else {
                print("nothing to do")
                return 0
            }
            try stage(release, in: shelf)
            print("downloaded and checked \(release.version)")
            guard let new = try apply(from: shelf, over: bundle) else { throw UpdateError("the downloaded version was not put in place") }
            print("updated to \(new)")
            return 0
        } catch {
            print("update failed: \(error)")
            return 1
        }
    }
}
