import Foundation
import Testing
@testable import NotesCore

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct NotebookTests {
    @Test func startsWithDefaultSections() throws {
        let root = temporaryFolder()
        let notebook = try Notebook(root: root)
        #expect(notebook.sections.map(\.title) == ["Сегодня", "Планы", "Идеи", "Заметки"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notebook.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path))
    }

    @Test func pagesSurviveReopening() throws {
        let root = temporaryFolder()
        let notebook = try Notebook(root: root)
        let page = try notebook.createPage(in: "Планы", text: "# Купить\n- [ ] хлеб\n")
        #expect(page.title == "Купить")
        let again = try Notebook(root: root)
        #expect(again.pages(in: "Планы").map(\.text) == ["# Купить\n- [ ] хлеб\n"])
        #expect(again.page(page.id)?.section == "Планы")
    }

    @Test func pageIDsStayUniqueAndOrdered() throws {
        let notebook = try Notebook(root: temporaryFolder())
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try notebook.createPage(in: "Идеи", date: date)
        let b = try notebook.createPage(in: "Планы", date: date)
        let c = try notebook.createPage(in: "Идеи", date: date)
        #expect(Set([a.id, b.id, c.id]).count == 3)
        #expect(notebook.pages(in: "Идеи").map(\.id) == [a.id, c.id])
        #expect(a.created == date)
    }

    @Test func savingReportsChanges() throws {
        let notebook = try Notebook(root: temporaryFolder())
        let page = try notebook.createPage(in: "Сегодня")
        #expect(try notebook.setText("привет", of: page.id))
        #expect(try !notebook.setText("привет", of: page.id))
        #expect(try String(contentsOf: notebook.fileURL(of: notebook.page(page.id)!), encoding: .utf8) == "привет")
    }

    @Test func movingAndDeletingPages() throws {
        let notebook = try Notebook(root: temporaryFolder())
        let page = try notebook.createPage(in: "Сегодня", text: "x")
        let moved = try notebook.movePage(page.id, to: "Идеи")
        #expect(notebook.pages(in: "Сегодня").isEmpty)
        #expect(FileManager.default.fileExists(atPath: notebook.fileURL(of: moved).path))
        try notebook.deletePage(page.id)
        #expect(notebook.pages(in: "Идеи").isEmpty)
        #expect(throws: NotebookError.noSuchPage(page.id)) { try notebook.deletePage(page.id) }
    }

    @Test func sectionLifecycle() throws {
        let root = temporaryFolder()
        let notebook = try Notebook(root: root)
        let books = try notebook.addSection(title: "Книги/Фильмы")
        #expect(books.folder == "Книги-Фильмы")
        #expect(throws: NotebookError.sectionExists("книги/фильмы")) { try notebook.addSection(title: "книги/фильмы") }
        #expect(throws: NotebookError.invalidName) { try notebook.addSection(title: " .. ") }
        let page = try notebook.createPage(in: books.folder, text: "Дюна")
        let renamed = try notebook.renameSection(books.folder, to: "Книги")
        #expect(notebook.page(page.id)?.section == "Книги")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Книги/\(page.id).md").path))
        #expect(throws: NotebookError.sectionNotEmpty("Книги")) { try notebook.removeSection(renamed.folder) }
        try notebook.moveSections(from: [4], to: 0)
        #expect(notebook.sections.first?.title == "Книги")
        #expect(try Notebook(root: root).sections.first?.title == "Книги")
        try notebook.deletePage(page.id)
        try notebook.removeSection("Книги")
        #expect(!notebook.sections.contains { $0.folder == "Книги" })
    }

    @Test func foldersMadeByHandBecomeSections() throws {
        let root = temporaryFolder()
        let notebook = try Notebook(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Работа"), withIntermediateDirectories: true)
        try "# Созвон".write(to: root.appendingPathComponent("Работа/2026-10-16-100000.md"), atomically: true, encoding: .utf8)
        try notebook.reload()
        #expect(notebook.sections.last?.title == "Работа")
        #expect(notebook.pages(in: "Работа").first?.title == "Созвон")
    }

    @Test func attachmentsAreStoredOnceAndResolve() throws {
        let root = temporaryFolder()
        let notebook = try Notebook(root: root)
        let data = Data("png".utf8)
        let link = try notebook.importAttachment(data, fileExtension: "PNG")
        #expect(try notebook.importAttachment(data, fileExtension: "png") == link)
        #expect(link.hasPrefix("../attachments/") && link.hasSuffix(".png"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("attachments").path)
        #expect(files.count == 1)
        let url = try #require(notebook.resolve(link, inSection: "Идеи"))
        #expect(try Data(contentsOf: url) == data)
        #expect(notebook.resolve("../../etc/passwd", inSection: "Идеи") == nil)
        #expect(notebook.resolve("https://example.com/a", inSection: "Идеи")?.absoluteString == "https://example.com/a")
    }
}
