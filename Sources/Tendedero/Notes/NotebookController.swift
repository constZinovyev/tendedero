import AppKit
import Combine
import NotesCore

/// The notebook on the line: it keeps the notes repository in step, hangs
/// the closed notebook, and opens the book over the desktop when clicked.
///
/// The notes are sealed under a password. Until it is typed the app holds
/// only the folder and git; the key and the open pages exist in memory
/// from the password until the notebook locks again.
@MainActor
final class NotebookController {
    private let line: Line
    private let linePanel: () -> LinePanel?
    private(set) var store: NotesStore?
    private var root: URL?
    private var sync: NotebookSync?
    private var card: PasswordCard?
    private var lockTimer: Timer?
    private var storeObservers = Set<AnyCancellable>()
    private var systemObservers: [NSObjectProtocol] = []
    private var panel: BookPanel?
    private var book: BookView?
    private var freePanel: FreeNotebookPanel?
    private var outsideClicks: Any?
    private var observers = Set<AnyCancellable>()
    private(set) var isOpen = false

    /// Whether the notebook hangs on the line. On by default.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "notebookOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "notebookOff") }
    }

    /// Off the rope, lying on the desktop where it was put down.
    static var isFree: Bool {
        get { UserDefaults.standard.bool(forKey: "notebookFree") }
        set { UserDefaults.standard.set(newValue, forKey: "notebookFree") }
    }

    /// The top centre of the free notebook's cover, on screen.
    private static var freeSpot: NSPoint? {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: "notebookFreeX") != nil else { return nil }
            return NSPoint(x: d.double(forKey: "notebookFreeX"), y: d.double(forKey: "notebookFreeY"))
        }
        set {
            UserDefaults.standard.set(newValue.map { Double($0.x) }, forKey: "notebookFreeX")
            UserDefaults.standard.set(newValue.map { Double($0.y) }, forKey: "notebookFreeY")
        }
    }

    init(line: Line, linePanel: @escaping () -> LinePanel?) {
        self.line = line
        self.linePanel = linePanel
        line.onNotebookTap = { [weak self] in self?.toggle() }
        line.onNotebookTearOff = { [weak self] in self?.tearOff() }
        line.onNotebookFreeDrag = { [weak self] in self?.carry() }
        line.onNotebookFreeDrop = { [weak self] in self?.putDown() }
        // Locking the screen or sleeping locks the notebook right away.
        let lockNow: (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.lock() } }
        systemObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow))
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main, using: lockNow))
        }
        if Self.isEnabled { start() }
    }

    /// How long the notebook stays open after the book is closed: 0 locks
    /// it at once. Five minutes unless chosen otherwise.
    static var lockAfter: TimeInterval {
        get { UserDefaults.standard.object(forKey: "notebookLockAfter") as? Double ?? 300 }
        set { UserDefaults.standard.set(newValue, forKey: "notebookLockAfter") }
    }

    /// The stickers' colours, kept for the closed notebook: the sections
    /// themselves are sealed. Colours alone say nothing.
    private static var cachedTabs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "notebookTabColors") ?? Notebook.defaultSections.map(\.color) }
        set { UserDefaults.standard.set(newValue, forKey: "notebookTabColors") }
    }

    private func setTabs(_ colors: [String]) {
        line.notebookTabs = colors
        freePanel?.model.tabs = colors
    }

    var isLocked: Bool { store == nil }

    private func start() {
        if root == nil {
            do {
                let folder = try NotesStore.prepareFolder()
                let sync = NotebookSync(root: folder)
                sync.privateMessages = true
                root = folder
                self.sync = sync
                sync.syncNow()
            } catch {
                log.error("Notebook: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        setTabs(Self.cachedTabs)
        if Self.isFree, let spot = Self.freeSpot {
            showFree(coverTop: spot)
            line.notebookShown = false
        } else {
            Self.isFree = false
            line.notebookShown = true
        }
    }

    // MARK: Off the rope

    private func makeFreePanel() -> FreeNotebookPanel {
        if let freePanel { return freePanel }
        let panel = FreeNotebookPanel()
        panel.model.tabs = line.notebookTabs
        panel.onTap = { [weak self] in self?.toggle() }
        panel.onDrop = { [weak self] in self?.putDown() }
        freePanel = panel
        return panel
    }

    private func showFree(coverTop: NSPoint) {
        let panel = makeFreePanel()
        panel.applyLevel()
        panel.place(coverTop: coverTop)
        panel.model.hidden = false
        panel.orderFrontRegardless()
    }

    /// The hand holds the cover a little below its top edge.
    private var underHand: NSPoint {
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x, y: mouse.y + 26)
    }

    /// Pulled off the pin: from here the drag carries the free notebook.
    private func tearOff() {
        showFree(coverTop: underHand)
        freePanel?.model.moving = true
        if !UserDefaults.standard.bool(forKey: "soundOff"), let pop = NSSound(named: "Pop")?.copy() as? NSSound {
            pop.volume = 0.2
            pop.play()
        }
    }

    private func carry() {
        freePanel?.place(coverTop: underHand)
    }

    /// Let go: back on the rope if brought up to it, otherwise it stays
    /// where it was put down.
    private func putDown() {
        guard let panel = freePanel else { return }
        panel.model.moving = false
        if let spot = ropeSpot(for: panel.coverFrame) {
            panel.orderOut(nil)
            Self.isFree = false
            line.moveNotebook(to: spot)
            line.saveNotebookPosition()
            line.notebookShown = true
        } else {
            Self.isFree = true
            Self.freeSpot = NSPoint(x: panel.coverFrame.midX, y: panel.coverFrame.maxY)
            line.notebookShown = false
        }
    }

    /// Where on the rope a notebook brought this close would hang, as a
    /// fraction of the line, or nil when it is not near the rope.
    private func ropeSpot(for cover: CGRect) -> Double? {
        guard line.revealed, let lp = linePanel(), lp.frame.width > 0 else { return nil }
        let x = cover.minX + (cover.width + NotebookLook.tabReach) / 2 - lp.frame.minX
        guard x >= 0, x <= lp.frame.width else { return nil }
        let rope = lp.frame.maxY - line.topOffset - Layout.ropeY(x: x, width: lp.frame.width)
        guard abs(cover.maxY - rope) < 46 else { return nil }
        return Double(x / lp.frame.width)
    }

    /// Back on the rope, where it hung last.
    func hangBack() {
        freePanel?.orderOut(nil)
        Self.isFree = false
        line.notebookShown = Self.isEnabled
    }

    func setEnabled(_ on: Bool) {
        Self.isEnabled = on
        if on {
            start()
        } else {
            if isOpen { close() }
            line.notebookShown = false
            freePanel?.orderOut(nil)
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    /// Where the closed notebook hangs on screen, from the line's layout:
    /// the same spot whether the line is down or tucked away.
    private func hangingFrame() -> CGRect? {
        if Self.isFree, let freePanel { return freePanel.coverFrame }
        guard let panel = linePanel() else { return nil }
        let width = panel.frame.width
        let x = CGFloat(line.notebookPosition) * width
        let top = line.topOffset + Layout.ropeY(x: x, width: width) - Layout.pinAbove + 26 - 12
        let size = NotebookLook.hangingSize
        return CGRect(x: panel.frame.minX + x - (size.width + NotebookLook.tabReach) / 2,
                      y: panel.frame.maxY - top - size.height, width: size.width, height: size.height)
    }

    func open() {
        lockTimer?.invalidate()
        guard Self.isEnabled, !isOpen else { return }
        if store == nil {
            askForPassword(Vault.exists(at: root ?? URL(fileURLWithPath: "/nonexistent")) ? .unlock : .create)
            return
        }
        let free = Self.isFree && freePanel != nil
        guard !isOpen, Self.isEnabled, let store, let from = hangingFrame(),
              let screen = (free ? freePanel?.screen : linePanel()?.screen) ?? NSScreen.main else { return }
        if panel == nil {
            let book = BookView(store: store)
            book.onClose = { [weak self] in self?.close() }
            let panel = BookPanel(content: book)
            panel.onEscape = { [weak self] in self?.close() }
            self.book = book
            self.panel = panel
        }
        guard let panel, let book, !book.animating else { return }
        isOpen = true
        panel.applyLevel()
        if free {
            panel.place(around: from, on: screen)
            freePanel?.model.hidden = true
        } else {
            panel.place(under: from, on: screen)
        }
        panel.makeKeyAndOrderFront(nil)
        line.notebookOpen = true
        book.open(from: panel.convertFromScreen(from)) {}
        // A click anywhere off the book closes it, like putting it down.
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) else { return }
                self.close()
            }
        }
    }

    func close() {
        guard isOpen, let panel, let book, !book.animating else { return }
        isOpen = false
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        let to = hangingFrame().map(panel.convertFromScreen) ?? BookGeometry.cover
        book.close(to: to) { [weak self] in
            panel.orderOut(nil)
            self?.freePanel?.model.hidden = false
            self?.line.notebookOpen = false
            self?.store?.syncNow()
            self?.scheduleLock()
        }
    }

    // MARK: The password

    private func askForPassword(_ mode: PasswordCard.Mode) {
        guard card == nil, let root, let near = hangingFrame() else { return }
        let card = PasswordCard(mode: mode) { [weak self] model in self?.submit(model, root: root) }
        card.onCancel = { [weak self] in self?.card = nil }
        self.card = card
        card.place(under: near)
        card.makeKeyAndOrderFront(nil)
    }

    private func submit(_ model: PasswordModel, root: URL) {
        let mode = model.mode, old = model.old, password = model.first
        if mode != .unlock {
            guard password.count >= Vault.minimumLength else { return model.fail(VaultError.weakPassword.localizedDescription) }
            guard password == model.second else { return model.fail("Пароли не совпадают.") }
        }
        model.error = nil
        model.working = true
        // A guess takes most of a second on purpose: off the main thread.
        Task.detached(priority: .userInitiated) {
            let result: Result<VaultKey?, Error> = Result {
                switch mode {
                case .create: return try Vault.create(at: root, password: password)
                case .unlock: return try Vault.unlock(at: root, password: password)
                case .change:
                    try Vault.changePassword(at: root, from: old, to: password)
                    return nil
                }
            }
            await MainActor.run { [weak self] in self?.finished(result, model: model, root: root) }
        }
    }

    private func finished(_ result: Result<VaultKey?, Error>, model: PasswordModel, root: URL) {
        switch result {
        case .failure(let error):
            model.fail(error.localizedDescription)
        case .success(nil):
            card?.orderOut(nil)
            card = nil
            sync?.syncNow()
        case .success(let key?):
            do {
                try unlock(with: key, root: root)
                card?.orderOut(nil)
                card = nil
                open()
            } catch {
                model.fail(error.localizedDescription)
            }
        }
    }

    /// Opens the sealed pages. A plain notebook from before the password is
    /// sealed into it the first time, and its plain files are taken away.
    private func unlock(with key: VaultKey, root: URL) throws {
        guard let sync else { return }
        let sealed = try SealedNotebook(root: root, key: key)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(Notebook.manifestName).path) {
            try sealed.adopt(Notebook(root: root))
            log.notice("Notebook: the plain pages are sealed now")
        }
        let store = NotesStore(notebook: sealed, sync: sync)
        store.$sections.sink { [weak self] sections in
            let colors = sections.map(\.color)
            Self.cachedTabs = colors
            self?.setTabs(colors)
        }
        .store(in: &storeObservers)
        store.$problem.compactMap { $0 }.sink { log.error("Notebook: \($0, privacy: .public)") }
            .store(in: &storeObservers)
        self.store = store
    }

    private func scheduleLock() {
        lockTimer?.invalidate()
        if Self.lockAfter <= 0 { return lock() }
        lockTimer = Timer.scheduledTimer(withTimeInterval: Self.lockAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }

    /// Forgets the key and every open page. An open book is put away at once.
    func lock() {
        lockTimer?.invalidate()
        card?.orderOut(nil)
        card = nil
        guard let store else { return }
        if isOpen {
            isOpen = false
            if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
            outsideClicks = nil
            panel?.orderOut(nil)
            freePanel?.model.hidden = false
            line.notebookOpen = false
        }
        store.close()
        sync?.syncNow()
        storeObservers.removeAll()
        self.store = nil
        book = nil
        panel = nil
        Thumbnails.forget()
        OpenedFiles.wipe()
        log.notice("Notebook: locked")
    }

    func finish() {
        store?.saveNow()
        sync?.finish(timeout: 5)
        OpenedFiles.wipe()
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        let shown = ClosureMenuItem(L("On the line", "En el tendedero")) { [weak self] in
            self?.setEnabled(!Self.isEnabled)
        }
        shown.state = Self.isEnabled ? .on : .off
        menu.addItem(shown)
        let open = ClosureMenuItem(isOpen ? L("Close notebook", "Cerrar cuaderno") : L("Open notebook", "Abrir cuaderno")) { [weak self] in
            self?.toggle()
        }
        open.keyEquivalent = "n"
        open.keyEquivalentModifierMask = [.option, .command]
        open.isEnabled = Self.isEnabled && store != nil
        menu.addItem(open)
        if Self.isFree {
            menu.addItem(ClosureMenuItem(L("Hang it back on the line", "Volver a colgarlo")) { [weak self] in self?.hangBack() })
        }
        menu.addItem(.separator())
        let lockItem = ClosureMenuItem(L("Lock now", "Bloquear ahora")) { [weak self] in self?.lock() }
        lockItem.isEnabled = store != nil
        menu.addItem(lockItem)
        let after = NSMenuItem(title: L("Lock after closing", "Bloquear al cerrar"), action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for (title, seconds) in [(L("Right away", "Enseguida"), 0.0), (L("After 5 minutes", "A los 5 minutos"), 300),
                                 (L("After 1 hour", "A la hora"), 3600)] {
            let item = ClosureMenuItem(title) { [weak self] in
                Self.lockAfter = seconds
                if self?.isOpen == false, self?.store != nil { self?.scheduleLock() }
            }
            item.state = Self.lockAfter == seconds ? .on : .off
            choices.addItem(item)
        }
        after.submenu = choices
        menu.addItem(after)
        let change = ClosureMenuItem(L("Change password…", "Cambiar contraseña…")) { [weak self] in self?.askForPassword(.change) }
        change.isEnabled = root.map(Vault.exists(at:)) ?? false
        menu.addItem(change)
        menu.addItem(.separator())
        let syncItem = ClosureMenuItem(L("Sync now", "Sincronizar ahora")) { [weak self] in
            self?.store?.saveNow()
            self?.sync?.syncNow()
        }
        syncItem.isEnabled = sync != nil
        if let store, case .failed(let message) = store.syncState { syncItem.toolTip = message }
        menu.addItem(syncItem)
        return menu
    }
}

/// The panel the open book lies in: no frame, its own shadow, and it takes
/// the keyboard without bringing Tendedero forward, so you can write.
final class BookPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(content: NSView) {
        super.init(contentRect: CGRect(origin: .zero, size: BookGeometry.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Paper is paper in dark mode too.
        appearance = NSAppearance(named: .aqua)
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    func applyLevel() {
        level = Placement.behindWindows
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
            : .floating
    }

    /// Hangs the book from the notebook's spot, kept on the screen.
    func place(under notebook: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = BookGeometry.size
        var x = notebook.midX - BookGeometry.spineX
        x = min(max(x, visible.minX), visible.maxX - size.width)
        var y = notebook.maxY + 6 - size.height
        y = max(y, visible.minY)
        setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    /// Opens the book where the free notebook lies, its spine over it.
    func place(around notebook: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = BookGeometry.size
        var x = notebook.midX - BookGeometry.spineX
        x = min(max(x, visible.minX), visible.maxX - size.width)
        var y = notebook.midY - BookGeometry.base.midY
        y = min(max(y, visible.minY), visible.maxY - size.height)
        setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The rustle of a page, made once from filtered noise: a soft hiss with
/// a few crackles of paper, quiet, and only when sounds are on.
enum Rustle {
    private static let sound: NSSound? = NSSound(data: wave(seconds: 0.42, seed: 7))
    private static let soft: NSSound? = NSSound(data: wave(seconds: 0.3, seed: 3))

    @MainActor
    static func play(soft quiet: Bool = false) {
        guard !UserDefaults.standard.bool(forKey: "soundOff"), let s = (quiet ? soft : sound)?.copy() as? NSSound else { return }
        s.volume = quiet ? 0.18 : 0.26
        s.play()
    }

    private static func wave(seconds: Double, seed: UInt64) -> Data {
        let rate = 44_100
        let count = Int(Double(rate) * seconds)
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int64(bitPattern: state >> 11)) / Double(1 << 52) - 1
        }
        var samples = [Int16](repeating: 0, count: count)
        var low = 0.0, band = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(count)
            // Swells in, then trails off, like a page sliding over another.
            let envelope = sin(.pi * pow(t, 0.6)) * (1 - t * 0.4)
            let crackle = noise() > 0.995 ? noise() * 3 : 0
            low += 0.18 * (noise() - low)
            band += 0.5 * ((noise() - low) - band)
            let v = (band * 0.8 + crackle * 0.5) * envelope * 0.5
            samples[i] = Int16(max(-1, min(1, v)) * 32_000)
        }
        var data = Data()
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); put(UInt32(count * 2).littleEndian)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
