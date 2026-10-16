import AppKit
import Combine
import NotesCore

/// The open notebook for the window: what is selected, saving as you type,
/// and keeping git in step.
final class NotesStore: ObservableObject {
    static let defaultPath = "~/projects/personal_notes"
    static let defaultRemote = "git@github.com:constZinovyev/personal_notes.git"

    @Published private(set) var sections: [NotebookSection] = []
    @Published private(set) var pages: [Page] = []
    @Published var selectedSection: String? {
        didSet {
            guard oldValue != selectedSection else { return }
            saveNow()
            refreshPages()
            selectedPageID = pages.last?.id
        }
    }
    @Published var selectedPageID: String? {
        didSet { if oldValue != selectedPageID { saveNow() } }
    }
    @Published private(set) var syncState: NotebookSync.State = .idle
    @Published private(set) var lastSync: Date?
    /// Goes up when the open page's text changed other than by typing, so
    /// the editor loads it again.
    @Published private(set) var editorRevision = 0
    @Published var problem: String?

    let notebook: Notebook
    let sync: NotebookSync
    private var pending: (id: String, text: String)?
    private var saveTimer: Timer?
    private var pullTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Opens the notebook at NOTES_ROOT (no remote unless NOTES_REMOTE), or
    /// at the NotebookPath default, cloning it on the first run.
    static func open() throws -> NotesStore {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let path: String
        let remote: String?
        if let root = environment["NOTES_ROOT"] {
            path = root
            remote = environment["NOTES_REMOTE"]
        } else {
            path = defaults.string(forKey: "NotebookPath") ?? defaultPath
            remote = defaults.string(forKey: "NotebookRemote") ?? defaultRemote
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try NotebookSync.prepare(root: root, remote: remote)
        return NotesStore(notebook: try Notebook(root: root), sync: NotebookSync(root: root))
    }

    init(notebook: Notebook, sync: NotebookSync) {
        self.notebook = notebook
        self.sync = sync
        sections = notebook.sections
        selectedSection = sections.first?.folder
        refreshPages()
        selectedPageID = pages.last?.id

        sync.onStateChange = { [weak self] state in
            self?.syncState = state
            self?.lastSync = self?.sync.lastSync
        }
        sync.onRemoteChanges = { [weak self] in self?.remoteChanged() }
        pullTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.syncNow() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastSync ?? .distantPast) > 60 else { return }
            self.syncNow()
        })
        syncNow()
    }

    var selectedPage: Page? { selectedPageID.flatMap { id in pages.first { $0.id == id } } }

    // MARK: Editing

    func editorChanged(_ text: String, page id: String) {
        pending = (id, text)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let edit = pending else { return }
        pending = nil
        attempt {
            if try notebook.setText(edit.text, of: edit.id) {
                sync.noteChanged()
                refreshPages()
            }
        }
    }

    func newPage() {
        guard let folder = selectedSection else { return }
        saveNow()
        attempt {
            let page = try notebook.createPage(in: folder)
            refreshPages()
            selectedPageID = page.id
            sync.noteChanged()
        }
    }

    func deletePage(_ id: String) {
        if pending?.id == id { pending = nil }
        attempt {
            try notebook.deletePage(id)
            refreshPages()
            if selectedPageID == id { selectedPageID = pages.last?.id }
            sync.noteChanged()
        }
    }

    /// The move gets a commit of its own, so git sees a rename and the
    /// page's history carries on.
    func movePage(_ id: String, to folder: String) {
        saveNow()
        sync.commitNow()
        attempt {
            try notebook.movePage(id, to: folder)
            refreshPages()
            sync.commitNow()
            sync.noteChanged()
        }
    }

    // MARK: Sections

    func addSection(title: String) {
        attempt {
            let section = try notebook.addSection(title: title)
            sections = notebook.sections
            selectedSection = section.folder
            sync.noteChanged()
        }
    }

    func renameSection(_ folder: String, to title: String) {
        saveNow()
        attempt {
            let section = try notebook.renameSection(folder, to: title)
            sections = notebook.sections
            if selectedSection == folder { selectedSection = section.folder }
            refreshPages()
            sync.noteChanged()
        }
    }

    func removeSection(_ folder: String) {
        attempt {
            try notebook.removeSection(folder)
            sections = notebook.sections
            if selectedSection == folder { selectedSection = sections.first?.folder }
            sync.noteChanged()
        }
    }

    func moveSections(from source: IndexSet, to destination: Int) {
        attempt {
            try notebook.moveSections(from: source, to: destination)
            sections = notebook.sections
            sync.noteChanged()
        }
    }

    // MARK: History and sync

    func history(of page: Page) -> [Revision] {
        saveNow()
        sync.commitNow()
        return (try? sync.git.history(of: page.path)) ?? []
    }

    func contents(of revision: Revision) -> String? { try? sync.git.contents(of: revision) }

    func restore(_ id: String, text: String) {
        pending = nil
        attempt {
            try notebook.setText(text, of: id)
            refreshPages()
            editorRevision += 1
            sync.noteChanged()
        }
    }

    func syncNow() {
        saveNow()
        sync.syncNow()
    }

    /// Before quitting: everything saved and committed, pushed if the
    /// network answers in a few seconds.
    func finish() {
        saveNow()
        sync.finish(timeout: 5)
    }

    private func remoteChanged() {
        let open = selectedPage
        attempt { try notebook.reload() }
        sections = notebook.sections
        if let folder = selectedSection, !sections.contains(where: { $0.folder == folder }) { selectedSection = sections.first?.folder }
        refreshPages()
        if let open, pending == nil, notebook.page(open.id)?.text != open.text { editorRevision += 1 }
    }

    private func refreshPages() {
        pages = selectedSection.map(notebook.pages(in:)) ?? []
    }

    private func attempt(_ body: () throws -> Void) {
        do { try body() } catch { problem = error.localizedDescription }
    }
}
