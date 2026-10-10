import Foundation

/// A copy of the line and the settings, one per day for the last week.
///
/// Today's copy is rewritten a few seconds after the line changes, so it is
/// always fresh without a timer; the days before stay as they were. An empty
/// line is never written, so after "Take everything down" today's copy still
/// holds what hung before. Photos are copied with `copyItem`, which on APFS is
/// a clone: it takes no extra space until the original changes or is deleted.
@MainActor
enum Backup {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tendedero/Backups", isDirectory: true)
    }()

    static let keep = 7

    struct Day {
        let url: URL
        let date: Date
        let count: Int
    }

    private static var pending: DispatchWorkItem?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Called whenever the line changes. Waits for it to settle, so sliding a
    /// photo or a burst of screenshots writes one copy.
    static func schedule(_ line: Line) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak line] in
            guard let line else { return }
            MainActor.assumeIsolated { write(line) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Copying the photos and writing the lists happen off the main
    /// thread, one copy at a time, so the line never stops for a backup.
    private static let queue = DispatchQueue(label: "app.tendedero.backup", qos: .utility)

    private static func write(_ line: Line) {
        let live = line.items.filter { !$0.falling && !$0.flying }.map { (url: $0.url, position: $0.position) }
        guard !live.isEmpty else { return }
        let day = folder.appendingPathComponent(dayFormat.string(from: Date()), isDirectory: true)
        let domain = UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "app.tendedero.Tendedero") ?? [:]
        let folder = folder, keep = keep
        queue.async { writeFiles(live, to: day, settings: domain, in: folder, keep: keep) }
    }

    nonisolated private static func writeFiles(_ live: [(url: URL, position: Double)], to day: URL,
                                               settings domain: [String: Any], in folder: URL, keep: Int) {
        let fm = FileManager.default
        let temp = folder.appendingPathComponent(".writing-\(UUID().uuidString)", isDirectory: true)
        do {
            let photos = temp.appendingPathComponent("Photos", isDirectory: true)
            try fm.createDirectory(at: photos, withIntermediateDirectories: true)
            var entries: [[String: Any]] = []
            for (n, item) in live.enumerated() {
                let name = "\(n + 1)-\(item.url.lastPathComponent)"
                guard (try? fm.copyItem(at: item.url, to: photos.appendingPathComponent(name))) != nil else { continue }
                entries.append(["path": item.url.path, "file": name, "position": item.position])
            }
            let lineData = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
            try lineData.write(to: temp.appendingPathComponent("line.plist"))
            let settings = try PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
            try settings.write(to: temp.appendingPathComponent("settings.plist"))

            if fm.fileExists(atPath: day.path) { try fm.removeItem(at: day) }
            try fm.moveItem(at: temp, to: day)
        } catch {
            log.error("Could not write the backup: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }
        prune(folder, keep: keep)
    }

    /// Keeps the last `keep` days and clears what an interrupted write left.
    /// The days are named yyyy-MM-dd, so their names sort by date.
    nonisolated private static func prune(_ folder: URL, keep: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(".writing-") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        let days = names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
        for name in days.sorted(by: >).dropFirst(keep) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Saved days, newest first.
    static func days() -> [Day] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> Day? in
            guard let date = dayFormat.date(from: name) else { return nil }
            let url = folder.appendingPathComponent(name, isDirectory: true)
            return Day(url: url, date: date, count: entries(in: url).count)
        }
        .sorted { $0.date > $1.date }
    }

    private static func entries(in day: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: day.appendingPathComponent("line.plist")),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return list
    }

    /// Hangs that day's photos back where they were. Photos already on the
    /// line stay. A photo whose original is gone comes back from the copy,
    /// into Tendedero's own folder.
    static func restore(_ day: Day, into line: Line) {
        let fm = FileManager.default
        for entry in entries(in: day.url) {
            guard let path = entry["path"] as? String, let file = entry["file"] as? String else { continue }
            var url = URL(fileURLWithPath: path)
            if !fm.fileExists(atPath: url.path) {
                let copy = day.url.appendingPathComponent("Photos").appendingPathComponent(file)
                let target = uniqueURL(in: Inbox.folder, for: url.lastPathComponent)
                do {
                    try fm.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
                    try fm.copyItem(at: copy, to: target)
                    url = target
                } catch {
                    log.error("Could not restore \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    continue
                }
            }
            line.hang(url, quietly: true, at: entry["position"] as? Double)
        }
    }

    private static func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
