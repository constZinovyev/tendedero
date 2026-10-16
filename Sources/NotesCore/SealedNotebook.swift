import CryptoKit
import Foundation

/// What the app needs from a notebook, whether its pages are plain Markdown
/// files (`Notebook`) or sealed under a password (`SealedNotebook`).
public protocol NotebookStorage: AnyObject {
    var root: URL { get }
    var sections: [NotebookSection] { get }
    func reload() throws
    func pages(in folder: String) -> [Page]
    func page(_ id: String) -> Page?
    @discardableResult func createPage(in folder: String, text: String, date: Date) throws -> Page
    @discardableResult func setText(_ text: String, of id: String) throws -> Bool
    func deletePage(_ id: String) throws
    @discardableResult func movePage(_ id: String, to folder: String) throws -> Page
    @discardableResult func addSection(title: String, color: String?) throws -> NotebookSection
    @discardableResult func renameSection(_ folder: String, to title: String) throws -> NotebookSection
    func setColor(_ color: String, ofSection folder: String) throws
    func removeSection(_ folder: String) throws
    func moveSections(from source: IndexSet, to destination: Int) throws
    /// Keeps a picture or file and returns the link a page uses for it.
    func importAttachment(_ data: Data, fileExtension: String) throws -> String
    /// A link to somewhere on the web, as opposed to a file in the notebook.
    func webLink(_ link: String) -> URL?
    /// The contents of a file a page links to, if it is in the notebook.
    func attachment(_ link: String, inSection folder: String) -> Data?
    /// Where the page is kept, relative to the root, for its history.
    func storedPath(of page: Page) -> String
    /// The page's text in a stored file as it was in some version.
    func text(fromStored data: Data, path: String) -> String?
}

public extension NotebookStorage {
    @discardableResult func createPage(in folder: String) throws -> Page { try createPage(in: folder, text: "", date: Date()) }
    @discardableResult func addSection(title: String) throws -> NotebookSection { try addSection(title: title, color: nil) }
}

extension Notebook: NotebookStorage {
    public func webLink(_ link: String) -> URL? {
        guard let url = resolve(link, inSection: ""), !url.isFileURL else { return nil }
        return url
    }

    public func attachment(_ link: String, inSection folder: String) -> Data? {
        guard let url = resolve(link, inSection: folder), url.isFileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    public func storedPath(of page: Page) -> String { page.path }

    public func text(fromStored data: Data, path: String) -> String? { String(data: data, encoding: .utf8) }
}

/// The notebook under a password. Everything it writes is sealed: the
/// names of the sections, each page, each picture. On disk and on GitHub
/// there is only this:
///
///     vault.json              the key, sealed with the password
///     sections.sealed         titles, order and colours
///     pages/<name>.sealed     one page: its id, section and text
///     files/<name>.sealed     a picture or file
///
/// File names are keyed hashes, so they tell nothing either. Each page is a
/// file of its own, so git keeps its history, and a pull that brings pages
/// from elsewhere just adds files. Opened pages live only in memory.
public final class SealedNotebook: NotebookStorage {
    public static let sectionsFile = "sections.sealed"
    public static let pagesFolder = "pages"
    public static let filesFolder = "files"

    public let root: URL
    private let key: VaultKey
    public private(set) var sections: [NotebookSection] = []
    private var pagesBySection: [String: [Page]] = [:]
    private let fm = FileManager.default

    private struct Stored: Codable {
        var id: String
        var section: String
        var text: String
    }

    public init(root: URL, key: VaultKey) throws {
        self.root = root.standardizedFileURL
        self.key = key
        try fm.createDirectory(at: self.root.appendingPathComponent(Self.pagesFolder), withIntermediateDirectories: true)
        try fm.createDirectory(at: self.root.appendingPathComponent(Self.filesFolder), withIntermediateDirectories: true)
        try reload()
    }

    public func reload() throws {
        let sectionsURL = root.appendingPathComponent(Self.sectionsFile)
        var changed = false
        if fm.fileExists(atPath: sectionsURL.path) {
            let data = try key.open(Data(contentsOf: sectionsURL), as: Self.sectionsFile)
            guard let read = try? JSONDecoder().decode([NotebookSection].self, from: data) else {
                throw VaultError.damaged(Self.sectionsFile)
            }
            sections = read
        } else {
            sections = Notebook.defaultSections.map { NotebookSection(folder: Self.newID(), title: $0.title, color: $0.color) }
            changed = true
        }
        pagesBySection = Dictionary(uniqueKeysWithValues: sections.map { ($0.folder, []) })
        let folder = root.appendingPathComponent(Self.pagesFolder)
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        where file.pathExtension == "sealed" {
            let path = "\(Self.pagesFolder)/\(file.lastPathComponent)"
            guard let data = try? key.open(Data(contentsOf: file), as: path),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  file.deletingPathExtension().lastPathComponent == key.name(for: stored.id) else { continue }
            // A page from a section this copy has not heard of (a merge
            // kept our list of sections) gets its section back.
            if pagesBySection[stored.section] == nil {
                sections.append(NotebookSection(folder: stored.section, title: "Найденное",
                                                color: Notebook.palette[sections.count % Notebook.palette.count]))
                pagesBySection[stored.section] = []
                changed = true
            }
            pagesBySection[stored.section]!.append(Page(id: stored.id, section: stored.section, text: stored.text))
        }
        for folder in pagesBySection.keys { pagesBySection[folder]!.sort { $0.id < $1.id } }
        if changed { try saveSections() }
        try writeSidecars()
    }

    // MARK: Pages

    public func pages(in folder: String) -> [Page] { pagesBySection[folder] ?? [] }

    public func page(_ id: String) -> Page? {
        guard let (folder, index) = locate(id) else { return nil }
        return pagesBySection[folder]![index]
    }

    @discardableResult
    public func createPage(in folder: String, text: String, date: Date) throws -> Page {
        let taken = Set(pagesBySection.values.flatMap { $0.map(\.id) })
        return try insert(Page(id: PageID.make(date: date, taken: taken), section: folder, text: text))
    }

    private func insert(_ page: Page) throws -> Page {
        guard pagesBySection[page.section] != nil else { throw NotebookError.noSuchSection(page.section) }
        try write(page)
        pagesBySection[page.section]!.append(page)
        pagesBySection[page.section]!.sort { $0.id < $1.id }
        return page
    }

    @discardableResult
    public func setText(_ text: String, of id: String) throws -> Bool {
        guard let (folder, index) = locate(id) else { throw NotebookError.noSuchPage(id) }
        guard pagesBySection[folder]![index].text != text else { return false }
        pagesBySection[folder]![index].text = text
        try write(pagesBySection[folder]![index])
        return true
    }

    public func deletePage(_ id: String) throws {
        guard let (folder, index) = locate(id) else { throw NotebookError.noSuchPage(id) }
        try fm.removeItem(at: root.appendingPathComponent(storedPath(of: pagesBySection[folder]![index])))
        pagesBySection[folder]!.remove(at: index)
    }

    /// The page keeps its file: only the section written inside it changes,
    /// so its history goes on unbroken.
    @discardableResult
    public func movePage(_ id: String, to folder: String) throws -> Page {
        guard let (from, index) = locate(id) else { throw NotebookError.noSuchPage(id) }
        guard pagesBySection[folder] != nil else { throw NotebookError.noSuchSection(folder) }
        let old = pagesBySection[from]![index]
        guard from != folder else { return old }
        let moved = Page(id: old.id, section: folder, text: old.text)
        try write(moved)
        pagesBySection[from]!.remove(at: index)
        pagesBySection[folder]!.append(moved)
        pagesBySection[folder]!.sort { $0.id < $1.id }
        return moved
    }

    // MARK: Sections

    @discardableResult
    public func addSection(title: String, color: String?) throws -> NotebookSection {
        let name = try checkedTitle(title)
        let section = NotebookSection(folder: Self.newID(), title: name,
                                      color: color ?? Notebook.palette[sections.count % Notebook.palette.count])
        sections.append(section)
        pagesBySection[section.folder] = []
        try saveSections()
        return section
    }

    @discardableResult
    public func renameSection(_ folder: String, to title: String) throws -> NotebookSection {
        guard let index = sections.firstIndex(where: { $0.folder == folder }) else { throw NotebookError.noSuchSection(folder) }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() != sections[index].title.lowercased() { _ = try checkedTitle(trimmed) }
        guard !trimmed.isEmpty else { throw NotebookError.invalidName }
        sections[index].title = trimmed
        try saveSections()
        return sections[index]
    }

    public func setColor(_ color: String, ofSection folder: String) throws {
        guard let index = sections.firstIndex(where: { $0.folder == folder }) else { throw NotebookError.noSuchSection(folder) }
        sections[index].color = color
        try saveSections()
    }

    public func removeSection(_ folder: String) throws {
        guard let index = sections.firstIndex(where: { $0.folder == folder }) else { throw NotebookError.noSuchSection(folder) }
        guard pages(in: folder).isEmpty else { throw NotebookError.sectionNotEmpty(sections[index].title) }
        sections.remove(at: index)
        pagesBySection[folder] = nil
        try saveSections()
    }

    public func moveSections(from source: IndexSet, to destination: Int) throws {
        let moving = source.map { sections[$0] }
        var rest = sections.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - source.filter { $0 < destination }.count)
        sections = rest
        try saveSections()
    }

    // MARK: Attachments

    /// Sealed once, named by a keyed hash of its contents. The link keeps
    /// the file's kind, so the editor knows a picture.
    public func importAttachment(_ data: Data, fileExtension: String) throws -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = key.name(for: "file:" + digest)
        let path = "\(Self.filesFolder)/\(name).sealed"
        let url = root.appendingPathComponent(path)
        if !fm.fileExists(atPath: url.path) { try key.seal(data, as: path).write(to: url, options: .atomic) }
        let ext = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        return "\(Self.filesFolder)/\(name)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    public func webLink(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme, scheme.count > 1, !url.isFileURL else { return nil }
        return url
    }

    public func attachment(_ link: String, inSection folder: String) -> Data? {
        let parts = link.split(separator: "/")
        guard parts.count == 2, parts[0] == Self.filesFolder else { return nil }
        let name = String(parts[1].split(separator: ".").first ?? "")
        guard name.count == 32, name.allSatisfy(\.isHexDigit) else { return nil }
        let path = "\(Self.filesFolder)/\(name).sealed"
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path)) else { return nil }
        return try? key.open(data, as: path)
    }

    public func storedPath(of page: Page) -> String { "\(Self.pagesFolder)/\(key.name(for: page.id)).sealed" }

    public func text(fromStored data: Data, path: String) -> String? {
        guard let open = try? key.open(data, as: path) else { return nil }
        return (try? JSONDecoder().decode(Stored.self, from: open))?.text
    }

    // MARK: Moving a plain notebook in

    /// Seals every page and picture of a plain notebook into this one, then
    /// takes the plain files away. Links to its pictures are rewritten.
    /// For an empty sealed notebook only.
    public func adopt(_ plain: Notebook) throws {
        guard pagesBySection.values.allSatisfy(\.isEmpty) else { return }
        var ids: [String: String] = [:]
        sections = plain.sections.map { section in
            let id = Self.newID()
            ids[section.folder] = id
            return NotebookSection(folder: id, title: section.title, color: section.color)
        }
        pagesBySection = Dictionary(uniqueKeysWithValues: sections.map { ($0.folder, []) })
        try saveSections()
        for old in plain.sections {
            for page in plain.pages(in: old.folder) {
                var text = page.text
                for link in Set(Markdown.images(in: text).map(\.path) + Markdown.links(in: text).map(\.url)) {
                    guard let data = plain.attachment(link, inSection: old.folder) else { continue }
                    let ext = (link as NSString).pathExtension
                    text = text.replacingOccurrences(of: "(\(link))", with: "(\(try importAttachment(data, fileExtension: ext)))")
                }
                _ = try insert(Page(id: page.id, section: ids[old.folder]!, text: text))
            }
        }
        for section in plain.sections { try? fm.removeItem(at: root.appendingPathComponent(section.folder)) }
        try? fm.removeItem(at: root.appendingPathComponent(Notebook.manifestName))
        try? fm.removeItem(at: root.appendingPathComponent(Notebook.attachmentsFolder))
        try? Self.readme.write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    // MARK: Files

    private func write(_ page: Page) throws {
        let data = try JSONEncoder().encode(Stored(id: page.id, section: page.section, text: page.text))
        let path = storedPath(of: page)
        try key.seal(data, as: path).write(to: root.appendingPathComponent(path), options: .atomic)
    }

    private func saveSections() throws {
        let data = try JSONEncoder().encode(sections)
        try key.seal(data, as: Self.sectionsFile).write(to: root.appendingPathComponent(Self.sectionsFile), options: .atomic)
    }

    private func writeSidecars() throws {
        let attributes = root.appendingPathComponent(".gitattributes")
        if !fm.fileExists(atPath: attributes.path) { try "*.sealed binary\n".write(to: attributes, atomically: true, encoding: .utf8) }
        let readme = root.appendingPathComponent("README.md")
        if (try? String(contentsOf: readme, encoding: .utf8)) != Self.readme {
            try? Self.readme.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    private func locate(_ id: String) -> (String, Int)? {
        for (folder, pages) in pagesBySection {
            if let index = pages.firstIndex(where: { $0.id == id }) { return (folder, index) }
        }
        return nil
    }

    private func checkedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotebookError.invalidName }
        guard !sections.contains(where: { $0.title.lowercased() == trimmed.lowercased() }) else { throw NotebookError.sectionExists(title) }
        return trimmed
    }

    private static func newID() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    static let readme = """
    # Записная книжка

    Заметки из Tendedero, зашифрованные паролем (AES-256-GCM, ключ из пароля
    через PBKDF2-SHA256). Без пароля здесь ничего не прочитать: ни страниц,
    ни названий разделов. Открываются они только в Tendedero.

    """
}
