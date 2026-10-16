import Foundation
import Testing
@testable import NotesCore

/// Two copies of one notebook, as on two Macs, sharing a bare "GitHub".
@Suite struct GitTests {
    let remote: URL
    let here: URL
    let there: URL

    init() throws {
        let base = temporaryFolder()
        remote = base.appendingPathComponent("remote.git")
        here = base.appendingPathComponent("here")
        there = base.appendingPathComponent("there")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "--bare", "-b", "main"], in: remote)
    }

    func commit(_ git: Git) throws { try git.commitAll { NotebookSync.message(for: $0, git: git) } }

    @Test func firstSyncFillsAnEmptyRemote() throws {
        try NotebookSync.prepare(root: here, remote: remote.path)
        let git = Git(root: here)
        #expect(git.isRepository && !git.hasCommits)
        #expect(try !git.pull())
        _ = try Notebook(root: here)
        try commit(git)
        try git.push()
        #expect(try git.run(["log", "-1", "--format=%s"]).trimmed == "Новая записная книжка")
        try NotebookSync.prepare(root: there, remote: remote.path)
        #expect(try Notebook(root: there).sections.count == 4)
    }

    @Test func editsFromBothSidesMeetWithoutLoss() throws {
        try NotebookSync.prepare(root: here, remote: remote.path)
        let mine = Git(root: here)
        let notebook = try Notebook(root: here)
        let page = try notebook.createPage(in: "Планы", text: "# План\n- [ ] спорт\n")
        try commit(mine)
        try mine.push()

        try NotebookSync.prepare(root: there, remote: remote.path)
        let theirs = Git(root: there)
        let other = try Notebook(root: there)
        try other.setText("# План\n- [x] спорт\n", of: page.id)
        try other.createPage(in: "Идеи", text: "С телефона")
        try commit(theirs)
        try theirs.push()

        try notebook.setText("# План\n- [ ] спорт\n- [ ] книги\n", of: page.id)
        try commit(mine)
        #expect(try mine.pull())
        try mine.push()
        try notebook.reload()
        #expect(notebook.page(page.id)?.text == "# План\n- [ ] спорт\n- [ ] книги\n")
        #expect(notebook.pages(in: "Идеи").first?.text == "С телефона")

        let history = try mine.history(of: page.path)
        #expect(history.count == 3)
        #expect(history.first?.message == "Планы: «План»")
        #expect(try history.contains { try mine.contents(of: $0) == "# План\n- [x] спорт\n" })
        #expect(try mine.contents(of: history.last!) == "# План\n- [ ] спорт\n")
        #expect(try theirs.pull())
    }

    @Test func historyFollowsMovedPages() throws {
        try NotebookSync.prepare(root: here, remote: nil)
        let git = Git(root: here)
        let notebook = try Notebook(root: here)
        let page = try notebook.createPage(in: "Сегодня", text: "один")
        try commit(git)
        // The app commits a move on its own, so git sees a pure rename.
        let moved = try notebook.movePage(page.id, to: "Заметки")
        try commit(git)
        try notebook.setText("один и два", of: page.id)
        try commit(git)
        let history = try git.history(of: moved.path)
        #expect(history.map(\.path) == [moved.path, moved.path, page.path])
        #expect(try git.contents(of: #require(history.last)) == "один")
    }

    @Test func messagesNamePages() throws {
        let notebook = try Notebook(root: here)
        let a = try notebook.createPage(in: "Планы", text: "# Хлеб")
        let paths = [a.path, "Идеи/2026-01-01-000000.md", "attachments/x.png", "notebook.json"]
        #expect(NotebookSync.describe(paths, root: here) == "Планы: «Хлеб», Идеи: удалена 2026-01-01-000000")
        #expect(NotebookSync.describe(["attachments/x.png"], root: here) == "Вложения")
    }
}
