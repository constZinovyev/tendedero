import AppKit
import Combine
import NotesCore

/// The notebook on the line: it opens the notes repository, hangs the
/// closed notebook, and opens the book over the desktop when clicked.
@MainActor
final class NotebookController {
    private let line: Line
    private let linePanel: () -> LinePanel?
    private(set) var store: NotesStore?
    private var panel: BookPanel?
    private var book: BookView?
    private var outsideClicks: Any?
    private var observers = Set<AnyCancellable>()
    private(set) var isOpen = false

    /// Whether the notebook hangs on the line. On by default.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "notebookOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "notebookOff") }
    }

    init(line: Line, linePanel: @escaping () -> LinePanel?) {
        self.line = line
        self.linePanel = linePanel
        line.onNotebookTap = { [weak self] in self?.toggle() }
        if Self.isEnabled { start() }
    }

    private func start() {
        if store == nil {
            do {
                store = try NotesStore.open()
            } catch {
                log.error("Notebook: \(error.localizedDescription, privacy: .public)")
                return
            }
            store?.$sections.sink { [weak self] sections in self?.line.notebookTabs = sections.map(\.color) }
                .store(in: &observers)
            store?.$problem.compactMap { $0 }.sink { log.error("Notebook: \($0, privacy: .public)") }
                .store(in: &observers)
        }
        line.notebookShown = true
    }

    func setEnabled(_ on: Bool) {
        Self.isEnabled = on
        if on {
            start()
        } else {
            if isOpen { close() }
            line.notebookShown = false
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    /// Where the closed notebook hangs on screen, from the line's layout:
    /// the same spot whether the line is down or tucked away.
    private func hangingFrame() -> CGRect? {
        guard let panel = linePanel() else { return nil }
        let width = panel.frame.width
        let x = CGFloat(line.notebookPosition) * width
        let top = line.topOffset + Layout.ropeY(x: x, width: width) - Layout.pinAbove + 26 - 12
        let size = NotebookLook.hangingSize
        return CGRect(x: panel.frame.minX + x - (size.width + NotebookLook.tabReach) / 2,
                      y: panel.frame.maxY - top - size.height, width: size.width, height: size.height)
    }

    func open() {
        guard !isOpen, Self.isEnabled, let store, let from = hangingFrame(),
              let screen = linePanel()?.screen ?? NSScreen.main else { return }
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
        panel.place(under: from, on: screen)
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
            self?.line.notebookOpen = false
            self?.store?.syncNow()
        }
    }

    func finish() {
        store?.finish()
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
        let sync = ClosureMenuItem(L("Sync now", "Sincronizar ahora")) { [weak self] in self?.store?.syncNow() }
        sync.isEnabled = store != nil
        if let store, case .failed(let message) = store.syncState { sync.toolTip = message }
        menu.addItem(sync)
        menu.addItem(ClosureMenuItem(L("Show notes folder", "Mostrar carpeta de notas")) { [weak self] in
            guard let root = self?.store?.notebook.root else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root])
        })
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
