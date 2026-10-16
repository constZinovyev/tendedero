import CryptoKit
import Foundation

/// A tab of the notebook: a folder of pages.
public struct NotebookSection: Codable, Hashable, Identifiable {
    /// The folder's name, which is also how pages and the manifest refer to it.
    public var folder: String
    public var title: String
    /// The sticker's colour, as #RRGGBB.
    public var color: String
    public var id: String { folder }

    public init(folder: String, title: String, color: String) {
        self.folder = folder
        self.title = title
        self.color = color
    }
}

/// One page: a Markdown file named after the moment it was made,
/// like `Планы/2026-10-16-194512.md`.
public struct Page: Hashable, Identifiable {
    public let id: String
    public let section: String
    public internal(set) var text: String

    public var title: String { Markdown.title(of: text) }
    public var created: Date? { PageID.date(from: id) }
    /// Relative to the notebook's root.
    public var path: String { "\(section)/\(id).md" }
}

public enum NotebookError: LocalizedError, Equatable {
    case invalidName
    case sectionExists(String)
    case sectionNotEmpty(String)
    case noSuchSection(String)
    case noSuchPage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Такое название не подходит."
        case .sectionExists(let name): return "Раздел «\(name)» уже есть."
        case .sectionNotEmpty(let name): return "В разделе «\(name)» есть страницы. Сначала перенесите или удалите их."
        case .noSuchSection(let name): return "Нет раздела «\(name)»."
        case .noSuchPage(let id): return "Нет страницы \(id)."
        }
    }
}

/// The notebook as files in a folder (a git repository, kept in step by
/// `NotebookSync`):
///
///     notebook.json            title, order and colours of the sections
///     Сегодня/2026-10-16-0912.md
///     Планы/…
///     attachments/<hash>.png   pictures and files, linked as ../attachments/…
///
/// Everything is plain Markdown, so the notes read fine on GitHub or in any
/// editor, and a folder made by hand becomes a section on the next reload.
/// Not thread-safe: use it from one thread (the main one in the app).
public final class Notebook {
    public static let manifestName = "notebook.json"
    public static let attachmentsFolder = "attachments"
    public static let palette = ["#F2B84B", "#7FB77E", "#E57B6F", "#6FA8DC", "#B48EDB", "#E8A0BF", "#8FC9C3", "#C9A27E"]
    public static let defaultSections = ["Сегодня", "Планы", "Идеи", "Заметки"].enumerated().map {
        NotebookSection(folder: $0.element, title: $0.element, color: palette[$0.offset])
    }

    public let root: URL
    public private(set) var title = "Notes"
    public private(set) var sections: [NotebookSection] = []
    private var pagesBySection: [String: [Page]] = [:]
    private let fm = FileManager.default

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        try reload()
    }

    /// Reads everything again from disk, for after a pull.
    public func reload() throws {
        let manifestURL = root.appendingPathComponent(Self.manifestName)
        var manifest: Manifest
        var changed = false
        if let data = try? Data(contentsOf: manifestURL), let read = try? JSONDecoder().decode(Manifest.self, from: data) {
            manifest = read
        } else {
            manifest = Manifest(title: "Notes", sections: Self.defaultSections)
            changed = true
        }
        let folders = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { ![Self.attachmentsFolder, SealedNotebook.pagesFolder, SealedNotebook.filesFolder].contains($0) }
            .sorted()
        for folder in folders where !manifest.sections.contains(where: { $0.folder == folder }) {
            manifest.sections.append(NotebookSection(folder: folder, title: folder, color: Self.palette[manifest.sections.count % Self.palette.count]))
            changed = true
        }
        title = manifest.title
        sections = manifest.sections
        pagesBySection = [:]
        for section in sections {
            let folder = url(ofSection: section.folder)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            pagesBySection[section.folder] = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension == "md" }
                .map { Page(id: $0.deletingPathExtension().lastPathComponent, section: section.folder, text: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
                .sorted { $0.id < $1.id }
        }
        if changed { try saveManifest() }
        let readme = root.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) { try? Self.readme.write(to: readme, atomically: true, encoding: .utf8) }
    }

    // MARK: Pages

    /// Oldest first, the order they sit in the notebook.
    public func pages(in folder: String) -> [Page] { pagesBySection[folder] ?? [] }

    public func page(_ id: String) -> Page? {
        guard let (folder, index) = locate(id) else { return nil }
        return pagesBySection[folder]![index]
    }

    @discardableResult
    public func createPage(in folder: String, text: String = "", date: Date = Date()) throws -> Page {
        guard pagesBySection[folder] != nil else { throw NotebookError.noSuchSection(folder) }
        let taken = Set(pagesBySection.values.flatMap { $0.map(\.id) })
        let page = Page(id: PageID.make(date: date, taken: taken), section: folder, text: text)
        try write(page)
        pagesBySection[folder]!.append(page)
        pagesBySection[folder]!.sort { $0.id < $1.id }
        return page
    }

    /// Saves the page's new text. False when it was already that.
    @discardableResult
    public func setText(_ text: String, of id: String) throws -> Bool {
        guard let (folder, index) = locate(id) else { throw NotebookError.noSuchPage(id) }
        guard pagesBySection[folder]![index].text != text else { return false }
        pagesBySection[folder]![index].text = text
        try write(pagesBySection[folder]![index])
        return true
    }

    /// Deleted pages stay in the git history.
    public func deletePage(_ id: String) throws {
        guard let (folder, index) = locate(id) else { throw NotebookError.noSuchPage(id) }
        try fm.removeItem(at: fileURL(of: pagesBySection[folder]![index]))
        pagesBySection[folder]!.remove(at: index)
    }

    @discardableResult
    public func movePage(_ id: String, to folder: String) throws -> Page {
        guard let (from, index) = locate(id) else { throw NotebookError.noSuchPage(id) }
        guard pagesBySection[folder] != nil else { throw NotebookError.noSuchSection(folder) }
        let old = pagesBySection[from]![index]
        guard from != folder else { return old }
        let moved = Page(id: old.id, section: folder, text: old.text)
        try fm.moveItem(at: fileURL(of: old), to: fileURL(of: moved))
        pagesBySection[from]!.remove(at: index)
        pagesBySection[folder]!.append(moved)
        pagesBySection[folder]!.sort { $0.id < $1.id }
        return moved
    }

    // MARK: Sections

    @discardableResult
    public func addSection(title: String, color: String? = nil) throws -> NotebookSection {
        let folder = try folderName(for: title)
        let section = NotebookSection(folder: folder, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                              color: color ?? Self.palette[sections.count % Self.palette.count])
        try fm.createDirectory(at: url(ofSection: folder), withIntermediateDirectories: true)
        sections.append(section)
        pagesBySection[folder] = []
        try saveManifest()
        return section
    }

    /// Renames the section and its folder.
    @discardableResult
    public func renameSection(_ folder: String, to title: String) throws -> NotebookSection {
        guard let index = sections.firstIndex(where: { $0.folder == folder }) else { throw NotebookError.noSuchSection(folder) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFolder = Self.sanitize(trimmed) == folder ? folder : try folderName(for: trimmed)
        if newFolder != folder {
            try fm.moveItem(at: url(ofSection: folder), to: url(ofSection: newFolder))
            pagesBySection[newFolder] = (pagesBySection.removeValue(forKey: folder) ?? []).map {
                Page(id: $0.id, section: newFolder, text: $0.text)
            }
        }
        sections[index].folder = newFolder
        sections[index].title = trimmed
        try saveManifest()
        return sections[index]
    }

    public func setColor(_ color: String, ofSection folder: String) throws {
        guard let index = sections.firstIndex(where: { $0.folder == folder }) else { throw NotebookError.noSuchSection(folder) }
        sections[index].color = color
        try saveManifest()
    }

    /// Only an empty section can go.
    public func removeSection(_ folder: String) throws {
        guard let index = sections.firstIndex(where: { $0.folder == folder }) else { throw NotebookError.noSuchSection(folder) }
        guard pages(in: folder).isEmpty else { throw NotebookError.sectionNotEmpty(sections[index].title) }
        try? fm.removeItem(at: url(ofSection: folder))
        sections.remove(at: index)
        pagesBySection[folder] = nil
        try saveManifest()
    }

    /// Reorders the stickers, with the same meaning as SwiftUI's `onMove`.
    public func moveSections(from source: IndexSet, to destination: Int) throws {
        let moving = source.map { sections[$0] }
        var rest = sections.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        sections = rest
        try saveManifest()
    }

    // MARK: Attachments

    /// Stores a picture or file once, named after its contents, and returns
    /// the link a page uses for it, like `../attachments/1f2e….png`.
    public func importAttachment(_ data: Data, fileExtension: String) throws -> String {
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = ext.isEmpty ? hash : "\(hash).\(ext)"
        let folder = root.appendingPathComponent(Self.attachmentsFolder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        if !fm.fileExists(atPath: file.path) { try data.write(to: file, options: .atomic) }
        return "../\(Self.attachmentsFolder)/\(name)"
    }

    /// Where a link on a page in `folder` points: web links as they are,
    /// relative ones inside the notebook, nil for anything leaving it.
    public func resolve(_ link: String, inSection folder: String) -> URL? {
        if let url = URL(string: link), let scheme = url.scheme, scheme.count > 1 { return url }
        let path = link.removingPercentEncoding ?? link
        let url = url(ofSection: folder).appendingPathComponent(path).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") ? url : nil
    }

    // MARK: Files

    public func fileURL(of page: Page) -> URL { root.appendingPathComponent(page.path) }

    private func url(ofSection folder: String) -> URL { root.appendingPathComponent(folder, isDirectory: true) }

    private func write(_ page: Page) throws {
        try page.text.write(to: fileURL(of: page), atomically: true, encoding: .utf8)
    }

    private func locate(_ id: String) -> (String, Int)? {
        for (folder, pages) in pagesBySection {
            if let index = pages.firstIndex(where: { $0.id == id }) { return (folder, index) }
        }
        return nil
    }

    private func saveManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(Manifest(title: title, sections: sections))
        try data.write(to: root.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    private func folderName(for title: String) throws -> String {
        let folder = Self.sanitize(title)
        guard !folder.isEmpty, folder != Self.attachmentsFolder else { throw NotebookError.invalidName }
        guard !sections.contains(where: { $0.folder.lowercased() == folder.lowercased() }),
              !fm.fileExists(atPath: url(ofSection: folder).path) else { throw NotebookError.sectionExists(title) }
        return folder
    }

    static func sanitize(_ title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        return name
    }

    private struct Manifest: Codable {
        var version = 1
        var title: String
        var sections: [NotebookSection]
    }

    static let readme = """
    # Записная книжка

    Заметки из Tendedero Notes. Каждый раздел — папка, каждая страница — Markdown-файл,
    названный по времени создания. Картинки и файлы лежат в `attachments/`.
    Порядок и цвета разделов — в `notebook.json`.

    """
}

/// Page names: the moment the page was made, `yyyy-MM-dd-HHmmss`.
enum PageID {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    static func make(date: Date, taken: Set<String>) -> String {
        let base = formatter.string(from: date)
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    static func date(from id: String) -> Date? { formatter.date(from: String(id.prefix(17))) }
}
