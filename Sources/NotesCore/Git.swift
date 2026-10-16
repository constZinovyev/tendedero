import Foundation

public struct GitError: LocalizedError {
    public let arguments: [String]
    public let status: Int32
    public let output: String

    public var errorDescription: String? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git \(arguments.first ?? ""): \(text.isEmpty ? "exit \(status)" : text)"
    }
}

/// One saved version of a page.
public struct Revision: Hashable, Identifiable {
    public let hash: String
    public let date: Date
    public let message: String
    /// The page's path in that version (pages move between sections).
    public let path: String
    public var id: String { hash }
}

/// The git command line, run in the notebook's folder. It uses the user's
/// own git and SSH keys, and never waits for a password prompt.
public final class Git {
    public let root: URL
    public static var executable = URL(fileURLWithPath: "/usr/bin/git")

    public init(root: URL) { self.root = root }

    @discardableResult
    public func run(_ arguments: [String]) throws -> String {
        try Self.run(arguments, in: root)
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) throws -> String {
        String(decoding: try runData(arguments, in: directory), as: UTF8.self)
    }

    static func runData(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "core.quotepath=off"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        }
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Both pipes are drained at once, so a chatty stderr cannot stall git.
        let errors = ErrorBuffer()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { errors.data = err.fileHandleForReading.readDataToEndOfFile() }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(arguments: arguments, status: process.terminationStatus,
                           output: String(decoding: errors.data, as: UTF8.self) + String(decoding: output, as: UTF8.self))
        }
        return output
    }

    private final class ErrorBuffer { var data = Data() }

    public static func clone(_ remote: String, to destination: URL) throws {
        try run(["clone", "-q", remote, destination.path], in: destination.deletingLastPathComponent())
    }

    public var isRepository: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    public func initialize() throws { try run(["init", "-q", "-b", "main"]) }

    public var hasCommits: Bool { (try? run(["rev-parse", "--verify", "-q", "HEAD"])) != nil }
    public var head: String? { (try? run(["rev-parse", "HEAD"]))?.trimmed }
    public var remote: String? { (try? run(["remote", "get-url", "origin"]))?.trimmed }
    public var branch: String { (try? run(["symbolic-ref", "--short", "HEAD"]))?.trimmed ?? "main" }

    /// Paths with changes not yet committed, relative to the root.
    public func changedPaths() throws -> [String] {
        let out = try run(["status", "--porcelain", "-z", "--untracked-files=all"])
        var fields = out.split(separator: "\0").map(String.init)[...]
        var paths: [String] = []
        while let entry = fields.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.append(String(entry.dropFirst(3)))
            // A rename or copy is followed by the old path.
            if status.contains("R") || status.contains("C") { _ = fields.popFirst() }
        }
        return paths
    }

    /// Commits everything; the message is made from the changed paths.
    /// False when there was nothing to commit.
    @discardableResult
    public func commitAll(message: ([String]) -> String) throws -> Bool {
        try run(["add", "-A"])
        let paths = try changedPaths()
        guard !paths.isEmpty else { return false }
        try run(identity + ["commit", "-q", "-m", message(paths)])
        return true
    }

    /// Brings in origin's commits on top of ours. When the same lines were
    /// changed on both sides, ours win in the files, and theirs stay in the
    /// history. True when anything came in.
    public func pull() throws -> Bool {
        guard remote != nil else { return false }
        let branch = self.branch
        guard !(try run(["ls-remote", "--heads", "origin", branch])).trimmed.isEmpty else { return false }
        let before = head
        do {
            try run(identity + ["pull", "-q", "--rebase", "--autostash", "origin", branch])
        } catch {
            _ = try? run(["rebase", "--abort"])
            try run(identity + ["merge", "-q", "--no-edit", "-X", "ours", "--allow-unrelated-histories", "origin/\(branch)"])
        }
        return head != before
    }

    /// Sends our commits to origin when there are any it lacks.
    public func push() throws {
        guard remote != nil, hasCommits else { return }
        if let ahead = try? run(["rev-list", "--count", "@{u}..HEAD"]).trimmed, ahead == "0" { return }
        try run(["push", "-q", "-u", "origin", "HEAD"])
    }

    /// The versions of a file, newest first, following it across moves.
    public func history(of path: String) throws -> [Revision] {
        guard hasCommits else { return [] }
        let out = try run(["log", "--follow", "--name-only", "--format=%x1e%H%x1f%aI%x1f%s", "--", path])
        let dates = ISO8601DateFormatter()
        return out.split(separator: "\u{1e}").compactMap { record in
            let lines = record.split(separator: "\n")
            guard let header = lines.first else { return nil }
            let fields = header.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard fields.count == 3, let date = dates.date(from: String(fields[1])) else { return nil }
            return Revision(hash: String(fields[0]), date: date, message: String(fields[2]),
                            path: lines.count > 1 ? String(lines[1]) : path)
        }
    }

    /// The file as it was in that version; throws when it did not exist there.
    public func contents(of revision: Revision) throws -> String {
        try run(["show", "\(revision.hash):\(revision.path)"])
    }

    /// The same, as bytes, for sealed files.
    public func data(of revision: Revision) throws -> Data {
        try Self.runData(["show", "\(revision.hash):\(revision.path)"], in: root)
    }

    /// The user's own name and email when git has them, a stand-in otherwise.
    private lazy var identity: [String] = {
        if let email = try? run(["config", "user.email"]), !email.trimmed.isEmpty { return [] }
        return ["-c", "user.name=Tendedero Notes", "-c", "user.email=notes@tendedero.local"]
    }()
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
