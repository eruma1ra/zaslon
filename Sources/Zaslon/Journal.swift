import SwiftUI

/// One stretch without the VPN, as Zaslon saw it.
struct Outage: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date? // nil while it lasts
    var frozen: [String] = [] // names of the list entries that were stopped
    var refused = 0 // connections the gate turned away for lack of a tunnel
    var off = false // protection was switched off, so nothing was stopped
    var cut: Bool? // true: Zaslon stopped before the VPN came back, so when the outage ended is not known
}

/// The record of outages: when the VPN was gone, what was frozen, how many connections the gate refused.
/// Kept in a small file so it survives a restart. Used on the main thread.
final class Journal: ObservableObject {
    static let shared = Journal(file: NSHomeDirectory() + "/Library/Application Support/Zaslon/journal.json")

    @Published var outages: [Outage] = [] // newest first
    private let file: String?
    private var saving = false
    private static let disk = DispatchQueue(label: "zaslon.journal") // one writer, so files land in the order they were made

    /// `file: nil` keeps the journal in memory only (tests).
    init(file: String?) {
        self.file = file
        guard let file, let saved = FileManager.default.contents(atPath: file).flatMap({ try? Self.coder.1.decode([Outage].self, from: $0) }) else { return }
        // An outage left open by a crash or a quit: when it ended is not known. It is closed and marked as cut short.
        outages = saved.map { o in
            var o = o
            if o.end == nil { (o.end, o.cut) = (o.start, true) }
            return o
        }
    }

    private static let coder: (JSONEncoder, JSONDecoder) = {
        let (to, from) = (JSONEncoder(), JSONDecoder())
        (to.dateEncodingStrategy, from.dateDecodingStrategy) = (.secondsSince1970, .secondsSince1970) // keeps fractions of a second
        return (to, from)
    }()

    /// The VPN went away (`connected: false`) or came back.
    func mark(connected: Bool, off: Bool = false, at time: Date = Date()) {
        let open = outages.first?.end == nil && !outages.isEmpty
        if connected {
            guard open else { return }
            outages[0].end = time
        } else {
            guard !open else { return }
            outages.insert(Outage(start: time, off: off), at: 0)
            outages = Array(outages.prefix(50)) // ponytail: the last 50 outages; add paging if anyone needs more history
        }
        save()
    }

    /// These list entries are stopped right now. Only counts while an outage is open.
    func froze(_ names: [String]) {
        guard outages.first?.end == nil, let known = outages.first?.frozen else { return }
        let all = known + names.filter { !known.contains($0) }
        guard all != known else { return }
        outages[0].frozen = all
        save()
    }

    /// The gate turned a connection away. Only counts while an outage is open.
    // ponytail: a refusal in the instant before Zaslon notices the drop is not counted. Seen so far: the freeze
    // starts before the tunnel goes, so there is no such instant; if one shows up, hold the count for the next outage.
    func refuse() {
        guard outages.first?.end == nil, !outages.isEmpty else { return }
        outages[0].refused += 1
        save()
    }

    /// Writes the file half a second later and off the main thread. The journal is fed from the path that freezes
    /// apps, and nothing there may wait for the disk; changes that come in a burst share one write.
    private func save() {
        guard file != nil, !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.saving = false
            self.store(wait: false)
        }
    }

    /// Writes the file. `wait: true` returns only when it is on disk (tests).
    func store(wait: Bool) {
        guard let file, let data = try? Self.coder.0.encode(outages) else { return }
        let write = {
            try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: file), options: .atomic)
        }
        if wait { Self.disk.sync { _ = write() } } else { Self.disk.async { _ = write() } }
    }

    // MARK: words

    /// "28 s", "2 min 43 s", "1 h 5 min".
    static func lasted(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
        if h > 0 { return "\(h) \(t("ч", "h")) \(m) \(t("мин", "min"))" }
        return m > 0 ? "\(m) \(t("мин", "min")) \(s) \(t("с", "s"))" : "\(s) \(t("с", "s"))"
    }

    /// "19:49:38 – 19:50:06"; an outage of another day starts with its date.
    static func span(_ o: Outage, now: Date = Date()) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: t("ru_RU", "en_GB"))
        clock.dateFormat = Calendar.current.isDate(o.start, inSameDayAs: now) ? "HH:mm:ss" : "d MMM HH:mm:ss"
        let end = DateFormatter()
        end.dateFormat = "HH:mm:ss"
        return clock.string(from: o.start) + " – " + (o.cut == true ? "?" : o.end.map(end.string) ?? "…")
    }

    /// "3 connections"; Russian has three forms.
    static func connections(_ n: Int) -> String {
        let ru = n % 10 == 1 && n % 100 != 11 ? "соединение" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "соединения" : "соединений"
        return "\(n) " + t(ru, n == 1 ? "connection" : "connections")
    }

    /// What the outage did, one fact per line.
    static func facts(_ o: Outage) -> [String] {
        // Protection can be switched on in the middle of an outage: what was then frozen comes first.
        var lines = [!o.frozen.isEmpty ? t("Заморожено: ", "Frozen: ") + o.frozen.joined(separator: ", ")
            : o.off ? t("Защита была выключена", "Protection was switched off")
            : t("Ничего не заморожено", "Nothing was frozen")] // no reason given: Zaslon does not know why
        if o.refused > 0 { lines.append(t("Ворота отказали: ", "The gate refused: ") + connections(o.refused)) }
        return lines
    }

    /// The whole journal as plain text, for the Copy button.
    var text: String {
        outages.map { o in
            let length = o.end.map { o.cut == true ? "" : "  " + Self.lasted(Int($0.timeIntervalSince(o.start).rounded())) } ?? ""
            return ([Self.span(o) + length] + Self.facts(o).map { "  " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

/// The journal as shown in the tray window, in place of the list.
struct JournalView: View {
    @ObservedObject var journal: Journal
    @ObservedObject var lang = Lang.shared
    let close: () -> Void
    @Local private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(t("Журнал", "Journal")).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !journal.outages.isEmpty {
                    Text(t("обрывов: ", "outages: ") + "\(journal.outages.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)
            Divider()
            if journal.outages.isEmpty {
                Text(t("Обрывов VPN пока не было", "No VPN outage so far")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                Divider()
            }
            // ponytail: the latest six; the Copy button gives all of them. Add scrolling if six proves too few.
            ForEach(journal.outages.prefix(6)) { o in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(Journal.span(o)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        Spacer()
                        if let end = o.end, o.cut != true {
                            Text(Journal.lasted(Int(end.timeIntervalSince(o.start).rounded()))).font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if o.end == nil {
                            Text(t("идёт", "now")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Journal.facts(o), id: \.self) { Text($0).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                .padding(.vertical, 9)
                Divider()
            }
            HStack {
                if !journal.outages.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(journal.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Text(copied ? t("Скопировано", "Copied") : t("Скопировать", "Copy"))
                            .font(.system(size: 12, weight: .medium)).fixedSize().padding(.horizontal, 10).padding(.vertical, 5)
                            .modifier(Chip(outline: 0.25))
                    }
                }
                Spacer()
                Button(action: close) { Text(t("Закрыть", "Close")).padding(.vertical, 5).contentShape(Rectangle()) }
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.top, 12)
        }
    }
}
