import Foundation

/// Keeps the notebook's folder and its GitHub repository in step, off the
/// main thread. Edits are committed once typing pauses, and pushed; a sync
/// also pulls what was written elsewhere.
public final class NotebookSync {
    public enum State: Equatable {
        case idle
        case syncing
        case failed(String)
    }

    public let git: Git
    /// How long edits must pause before they are committed.
    public var commitDelay: TimeInterval = 30
    /// Called on the main thread.
    public var onStateChange: ((State) -> Void)?
    /// Called on the main thread when a pull brought in changes.
    public var onRemoteChanges: (() -> Void)?
    public private(set) var lastSync: Date?
    /// Commit messages that name nothing, for a sealed notebook: titles
    /// in them would be readable by anyone with the repository.
    public var privateMessages = false

    private let queue = DispatchQueue(label: "app.tendedero.notes.sync", qos: .utility)
    private var pendingCommit: DispatchWorkItem?

    public init(root: URL) { git = Git(root: root) }

    /// Makes `root` a git repository: a clone of `remote` when the folder is
    /// missing or empty, otherwise a new repository pointing at it.
    public static func prepare(root: URL, remote: String?) throws {
        let fm = FileManager.default
        let git = Git(root: root)
        if git.isRepository { return }
        let empty = (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true
        if let remote, empty {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try Git.clone(remote, to: root)
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try git.initialize()
            if let remote { try git.run(["remote", "add", "origin", remote]) }
        }
    }

    /// Call from the main thread after each saved edit.
    public func noteChanged() {
        pendingCommit?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.run(pull: false) }
        pendingCommit = item
        DispatchQueue.main.asyncAfter(deadline: .now() + commitDelay, execute: item)
    }

    /// Commits, pulls and pushes now. Call from the main thread.
    public func syncNow() {
        pendingCommit?.cancel()
        pendingCommit = nil
        run(pull: true)
    }

    /// Commits right away, waiting for it; for before reading the history.
    public func commitNow() {
        pendingCommit?.cancel()
        pendingCommit = nil
        queue.sync { [git] in _ = try? git.commitAll(message: { Self.message(for: $0, git: git, private: self.privateMessages) }) }
    }

    /// Commits and pushes before quitting, waiting at most `timeout` for the
    /// network. The commit itself always happens.
    public func finish(timeout: TimeInterval) {
        pendingCommit?.cancel()
        pendingCommit = nil
        let done = DispatchSemaphore(value: 0)
        queue.async { [git] in
            _ = try? git.commitAll(message: { Self.message(for: $0, git: git, private: self.privateMessages) })
            done.signal()
            try? git.push()
        }
        done.wait()
        let pushed = DispatchSemaphore(value: 0)
        queue.async { pushed.signal() }
        _ = pushed.wait(timeout: .now() + timeout)
    }

    private func run(pull: Bool) {
        onStateChange?(.syncing)
        queue.async { [git] in
            var state = State.idle
            var changed = false
            do {
                try git.commitAll(message: { Self.message(for: $0, git: git, private: self.privateMessages) })
                if pull { changed = try git.pull() }
                try git.push()
            } catch {
                state = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                if state == .idle { self.lastSync = Date() }
                self.onStateChange?(state)
                if changed { self.onRemoteChanges?() }
            }
        }
    }

    static func message(for paths: [String], git: Git, private hidden: Bool = false) -> String {
        guard git.hasCommits else { return "Новая записная книжка" }
        return hidden ? "Заметки обновлены" : describe(paths, root: git.root)
    }

    /// A commit message naming the pages that changed, like
    /// `Планы: «Купить хлеб», Идеи: «Сад на крыше»`.
    static func describe(_ paths: [String], root: URL) -> String {
        var parts: [String] = []
        var attachments = 0
        for path in paths {
            if path.hasPrefix(Notebook.attachmentsFolder + "/") {
                attachments += 1
                continue
            }
            let pieces = path.split(separator: "/")
            guard pieces.count == 2, path.hasSuffix(".md") else { continue }
            let section = pieces[0]
            if let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) {
                let title = Markdown.title(of: text)
                parts.append("\(section): «\(title.isEmpty ? "без названия" : title)»")
            } else {
                parts.append("\(section): удалена \(pieces[1].dropLast(3))")
            }
        }
        if parts.count > 3 { parts = Array(parts.prefix(3)) + ["и ещё \(parts.count - 3)"] }
        if parts.isEmpty { return attachments > 0 ? "Вложения" : "Оглавление" }
        return parts.joined(separator: ", ")
    }
}
