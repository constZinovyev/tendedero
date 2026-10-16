import CryptoKit
import Foundation
import Testing
@testable import NotesCore

/// Few rounds in tests, so they stay quick; the app calibrates its own.
private let quick: UInt32 = 1_000

@Suite struct VaultTests {
    @Test func onlyTheRightPasswordOpens() throws {
        let root = temporaryFolder()
        let key = try Vault.create(at: root, password: "долгий пароль", rounds: quick)
        #expect(throws: VaultError.exists) { try Vault.create(at: root, password: "ещё один пароль", rounds: quick) }
        #expect(throws: VaultError.wrongPassword) { try Vault.unlock(at: root, password: "долгий парол") }
        let again = try Vault.unlock(at: root, password: "долгий пароль")
        #expect(key.name(for: "x") == again.name(for: "x"))
        #expect(throws: VaultError.weakPassword) { try Vault.create(at: temporaryFolder(), password: "short", rounds: quick) }
    }

    @Test func composedAndDecomposedLettersAreOnePassword() throws {
        let root = temporaryFolder()
        _ = try Vault.create(at: root, password: "ёжик в тумане", rounds: quick)
        _ = try Vault.unlock(at: root, password: "ёжик в тумане".decomposedStringWithCanonicalMapping)
    }

    @Test func changingThePasswordKeepsThePages() throws {
        let root = temporaryFolder()
        let notebook = try SealedNotebook(root: root, key: Vault.create(at: root, password: "первый пароль", rounds: quick))
        let page = try notebook.createPage(in: notebook.sections[0].folder, text: "секрет", date: Date())
        try Vault.changePassword(at: root, from: "первый пароль", to: "второй пароль", rounds: quick)
        #expect(throws: VaultError.wrongPassword) { try Vault.unlock(at: root, password: "первый пароль") }
        let reopened = try SealedNotebook(root: root, key: Vault.unlock(at: root, password: "второй пароль"))
        #expect(reopened.page(page.id)?.text == "секрет")
    }

    @Test func nothingReadableIsWritten() throws {
        let root = temporaryFolder()
        let notebook = try SealedNotebook(root: root, key: Vault.create(at: root, password: "пароль-пароль", rounds: quick))
        let section = try notebook.addSection(title: "Тайный раздел")
        let link = try notebook.importAttachment(Data("картинка-тайна".utf8), fileExtension: "png")
        try notebook.createPage(in: section.folder, text: "# Тайна\nкод от сейфа 4321\n![](\(link))", date: Date())
        let everything = try FileManager.default.subpathsOfDirectory(atPath: root.path).compactMap {
            FileManager.default.contents(atPath: root.appendingPathComponent($0).path)
        }.reduce(Data(), +)
        for secret in ["Тайна", "4321", "Тайный раздел", "картинка-тайна", "Сегодня"] {
            #expect(everything.range(of: Data(secret.utf8)) == nil, "\(secret) is readable on disk")
        }
        #expect(!(try FileManager.default.subpathsOfDirectory(atPath: root.path)).contains { $0.contains("2026") || $0.contains("Тай") })
    }

    @Test func pagesComeBackAndSurviveReopening() throws {
        let root = temporaryFolder()
        let key = try Vault.create(at: root, password: "пароль-пароль", rounds: quick)
        let notebook = try SealedNotebook(root: root, key: key)
        let plans = notebook.sections[1].folder
        let page = try notebook.createPage(in: plans, text: "- [ ] хлеб", date: Date())
        let link = try notebook.importAttachment(Data([1, 2, 3]), fileExtension: "PNG")
        #expect(try notebook.importAttachment(Data([1, 2, 3]), fileExtension: "png") == link)
        #expect(notebook.attachment(link, inSection: plans) == Data([1, 2, 3]))
        #expect(notebook.attachment("files/../../vault", inSection: plans) == nil)
        #expect(notebook.webLink("https://example.com")?.host == "example.com")
        #expect(notebook.webLink(link) == nil)
        try notebook.renameSection(plans, to: "Дела")
        let moved = try notebook.movePage(page.id, to: notebook.sections[2].folder)
        let reopened = try SealedNotebook(root: root, key: Vault.unlock(at: root, password: "пароль-пароль"))
        #expect(reopened.sections.map(\.title) == ["Сегодня", "Дела", "Идеи", "Заметки"])
        #expect(reopened.page(page.id)?.section == moved.section)
        #expect(reopened.page(page.id)?.text == "- [ ] хлеб")
    }

    @Test func aSwappedOrForeignFileIsNotRead() throws {
        let root = temporaryFolder()
        let key = try Vault.create(at: root, password: "пароль-пароль", rounds: quick)
        let notebook = try SealedNotebook(root: root, key: key)
        let a = try notebook.createPage(in: notebook.sections[0].folder, text: "A", date: Date(timeIntervalSince1970: 1))
        let b = try notebook.createPage(in: notebook.sections[0].folder, text: "B", date: Date(timeIntervalSince1970: 2))
        let fileA = root.appendingPathComponent(notebook.storedPath(of: a))
        let fileB = root.appendingPathComponent(notebook.storedPath(of: b))
        try FileManager.default.removeItem(at: fileA)
        try FileManager.default.copyItem(at: fileB, to: fileA)
        try Data("garbage".utf8).write(to: root.appendingPathComponent("pages/0123.sealed"))
        try notebook.reload()
        #expect(notebook.pages(in: notebook.sections[0].folder).map(\.text) == ["B"])
        let other = temporaryFolder()
        let stranger = try SealedNotebook(root: other, key: Vault.create(at: other, password: "чужой пароль", rounds: quick))
        #expect(stranger.text(fromStored: try Data(contentsOf: fileB), path: notebook.storedPath(of: b)) == nil)
    }

    @Test func aPlainNotebookMovesIn() throws {
        let root = temporaryFolder()
        let plain = try Notebook(root: root)
        let link = try plain.importAttachment(Data("png".utf8), fileExtension: "png")
        let page = try plain.createPage(in: "Идеи", text: "Сад\n![](\(link))")
        try plain.addSection(title: "Книги")
        let notebook = try SealedNotebook(root: root, key: Vault.create(at: root, password: "пароль-пароль", rounds: quick))
        try notebook.adopt(plain)
        #expect(notebook.sections.map(\.title) == ["Сегодня", "Планы", "Идеи", "Заметки", "Книги"])
        let moved = try #require(notebook.page(page.id))
        let newLink = try #require(Markdown.images(in: moved.text).first?.path)
        #expect(newLink.hasPrefix("files/"))
        #expect(notebook.attachment(newLink, inSection: moved.section) == Data("png".utf8))
        for gone in ["Идеи", "Книги", "attachments", "notebook.json"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(gone).path))
        }
    }

    @Test func historyOfASealedPage() throws {
        let remote = temporaryFolder().appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Git.run(["init", "-q", "--bare", "-b", "main"], in: remote)
        let root = temporaryFolder().appendingPathComponent("notes")
        try NotebookSync.prepare(root: root, remote: remote.path)
        let git = Git(root: root)
        let notebook = try SealedNotebook(root: root, key: Vault.create(at: root, password: "пароль-пароль", rounds: quick))
        let page = try notebook.createPage(in: notebook.sections[0].folder, text: "первая", date: Date())
        try git.commitAll { NotebookSync.message(for: $0, git: git, private: true) }
        try notebook.setText("вторая", of: page.id)
        try notebook.movePage(page.id, to: notebook.sections[1].folder)
        try git.commitAll { NotebookSync.message(for: $0, git: git, private: true) }
        let path = notebook.storedPath(of: page)
        let history = try git.history(of: path)
        #expect(history.map(\.message) == ["Заметки обновлены", "Новая записная книжка"])
        #expect(try history.map { notebook.text(fromStored: try git.data(of: $0), path: $0.path) } == ["вторая", "первая"])
        #expect(try String(contentsOf: root.appendingPathComponent(".gitattributes"), encoding: .utf8).contains("binary"))
    }
}

@Suite struct FingerprintTests {
    /// The enclave's part played by a software key: the same sealing.
    @Test func theKeySealedForAFingerOpensTheSamePages() throws {
        let root = temporaryFolder()
        let key = try Vault.create(at: root, password: "пароль-пароль", rounds: 1_000)
        let notebook = try SealedNotebook(root: root, key: key)
        let page = try notebook.createPage(in: notebook.sections[0].folder, text: "тайна", date: Date())
        let device = P256.KeyAgreement.PrivateKey()
        let (ephemeral, sealed) = try Fingerprint.wrap(key.master, to: device.publicKey)
        let shared = try device.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ephemeral))
        let opened = VaultKey(master: try Fingerprint.unwrap(sealed, shared: shared, ephemeral: ephemeral))
        #expect(try SealedNotebook(root: root, key: opened).page(page.id)?.text == "тайна")
        let other = P256.KeyAgreement.PrivateKey()
        let wrong = try other.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ephemeral))
        #expect(throws: VaultError.self) { try Fingerprint.unwrap(sealed, shared: wrong, ephemeral: ephemeral) }
    }
}
