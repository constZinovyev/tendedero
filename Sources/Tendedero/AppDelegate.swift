import AppKit
import Carbon
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKeys: [HotKey] = []
    private var garlands: GarlandController!
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    private var lastLiveCount = 0
    /// The screen a new capture was taken on: the line goes there.
    private var pendingScreen: NSScreen?

    /// The line stays down instead of tucking away when the pointer leaves.
    /// The shortcut can still put it away until it is brought down again.
    private var alwaysShow: Bool {
        get { UserDefaults.standard.bool(forKey: "alwaysShow") }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysShow") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()

        // ⌥⌘T shows or hides the line. ⌃⌥⌘T keeps it down for good, or lets
        // it tuck away again.
        hotKeys = [
            HotKey(keyCode: kVK_ANSI_T, modifiers: optionKey | cmdKey) { [weak self] in
                self?.toggle()
            },
            HotKey(keyCode: kVK_ANSI_T, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
                self?.toggleAlwaysShow()
            },
        ]

        setUpStatusItem()
        garlands = GarlandController()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.cardScreenFrame = { [weak self] id in self?.hangingFrame(for: id) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.itemsChanged()
                Backup.schedule(self.line)
            }
            .store(in: &cancellables)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if alwaysShow { setAlwaysShow(true) }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Tendedero handle your screenshots?",
                              "¿Quieres que Tendedero se encargue de tus capturas?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.",
            "Las capturas se colgarán al instante, sin la miniatura flotante, y no se acumularán en el Escritorio. Arrastra una a una carpeta para guardarla, o descártala con la cruz. Puedes desactivarlo desde la barra de menús, y tus ajustes vuelven a ser los de antes al salir de Tendedero.")
        alert.addButton(withTitle: L("Turn on", "Activar"))
        alert.addButton(withTitle: L("Not now", "Ahora no"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    private func itemsChanged() {
        let live = line.liveCount
        if live > lastLiveCount {
            panel.placeOnScreen(pendingScreen)
            pendingScreen = nil
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        } else if live == 0 && !keepOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
                self.wanted = false
                self.refresh()
            }
        }
        lastLiveCount = live
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        if let from {
            let center = CGPoint(x: from.midX, y: from.midY)
            pendingScreen = NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
        }
        guard let id = line.hang(url, flying: from != nil), let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(3000, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), on: screen)
    }

    /// Where a card hangs right now, in screen coordinates, as the view
    /// reported it. Only while the line is down.
    private func hangingFrame(for id: UUID) -> CGRect? {
        guard isRevealed, let r = line.hitRects[id] else { return nil }
        return CGRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY,
                      width: r.width, height: r.height)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = CGFloat(line.items[index].position) * width
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = line.topOffset + viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.isActive(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.isActive(on:)) ?? false
        if wanted && !blocked {
            let wasPresent = isPresent
            present()
            // Back from full screen, an always shown line comes down again.
            if !wasPresent && alwaysShow { reveal() }
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 && !alwaysShow {
                keepOpen = false
                wanted = false
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    /// From the shortcut: turning it off puts the line away at once, so the
    /// key always does something you can see.
    private func toggleAlwaysShow() {
        if alwaysShow {
            setAlwaysShow(false)
            setRevealed(false)
        } else {
            setAlwaysShow(true)
        }
    }

    private func setAlwaysShow(_ on: Bool) {
        alwaysShow = on
        if on {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal()
        } else {
            keepOpen = false
            if line.liveCount == 0 {
                wanted = false
                refresh()
            }
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { Self.menuBarBand(of: $0).contains(p) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed && !self.alwaysShow {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { Self.menuBarBand(of: $0).contains(mouse) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if let screen = screenUnderPointer, inMenuBar, !menuBarSuppressed,
               Placement.allows(screen), !FullScreen.isActive(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = alwaysShow || pinned || GrabView.isDragging || line.slidingID != nil || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging, line.slidingID == nil else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        let overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    private func updateCapacity() {
        if panel.frame.width > 0 { line.width = panel.frame.width }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: "Tendedero")
        image?.isTemplate = true
        statusItem.button?.image = image
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line", "Ocultar tendedero")
                                                 : L("Show line", "Mostrar tendedero")) { [weak self] in
            self?.toggle()
        }
        toggleItem.keyEquivalent = "t"
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(toggleItem)

        let always = ClosureMenuItem(L("Always show", "Mostrar siempre")) { [weak self] in
            guard let self else { return }
            self.setAlwaysShow(!self.alwaysShow)
        }
        always.state = alwaysShow ? .on : .off
        always.keyEquivalent = "t"
        always.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(always)

        let clearItem = ClosureMenuItem(L("Take everything down…", "Descolgar todo…")) { [weak self] in
            self?.confirmClear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let restore = NSMenuItem(title: L("Restore from backup", "Restaurar copia"), action: nil, keyEquivalent: "")
        let days = Backup.days()
        if !days.isEmpty {
            let submenu = NSMenu()
            for day in days {
                submenu.addItem(ClosureMenuItem("\(Self.dayTitle(day.date)) — \(Self.photoCount(day.count))") { [weak self] in
                    guard let self else { return }
                    Backup.restore(day, into: self.line)
                })
            }
            restore.submenu = submenu
        }
        restore.isEnabled = !days.isEmpty
        menu.addItem(restore)

        let inbox = ClosureMenuItem(L("Handle screenshots", "Encargarse de las capturas")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop",
                          "Las capturas se cuelgan al instante y no pasan por el Escritorio")
        menu.addItem(inbox)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder", "Abrir carpeta de capturas")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds", "Sonidos")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let mainOnly = ClosureMenuItem(L("Main screen only", "Solo en la pantalla principal")) { [weak self] in
            Placement.mainScreenOnly.toggle()
            self?.moveLine()
            self?.garlands.refresh()
        }
        mainOnly.state = Placement.mainScreenOnly ? .on : .off
        mainOnly.toolTip = L("The line hangs only on the screen with the Dock",
                             "El tendedero solo se cuelga en la pantalla con el Dock")
        menu.addItem(mainOnly)

        let behind = ClosureMenuItem(L("Behind windows", "Detrás de las ventanas")) { [weak self] in
            Placement.behindWindows.toggle()
            self?.panel.applyLevel()
        }
        behind.state = Placement.behindWindows ? .on : .off
        behind.toolTip = L("The line hangs on the desktop, under every window",
                           "El tendedero se cuelga en el escritorio, bajo todas las ventanas")
        menu.addItem(behind)

        let offset = NSMenuItem()
        offset.view = SliderMenuView(
            title: L("Distance from the top", "Distancia desde arriba"),
            value: Double(Placement.topOffset), range: 0...Double(Placement.maxTopOffset)
        ) { [weak self] value in
            self?.setTopOffset(CGFloat(value))
        }
        menu.addItem(offset)

        let garlandItem = NSMenuItem(title: L("Garlands", "Guirnaldas"), action: nil, keyEquivalent: "")
        garlandItem.submenu = garlands.menu()
        menu.addItem(garlandItem)

        let login = ClosureMenuItem(L("Open at login", "Abrir al iniciar sesión")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero", "Salir de Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// Asks first: one click in the menu should not empty the whole line.
    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = L("Take everything down?", "¿Descolgar todo?")
        alert.informativeText = L(
            "All \(Self.photoCount(line.liveCount)) come off the line. The files stay where they are, and today's backup keeps what was hanging.",
            "Se descuelgan \(Self.photoCount(line.liveCount)). Los archivos se quedan donde están, y la copia de hoy guarda lo que estaba colgado.")
        alert.alertStyle = .warning
        let takeDown = alert.addButton(withTitle: L("Take down", "Descolgar"))
        takeDown.hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel", "Cancelar"))
        if let icon = NSImage(named: "Tendedero") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { line.clear() }
    }

    private static func photoCount(_ n: Int) -> String {
        n == 1 ? L("1 photo", "1 foto") : L("\(n) photos", "\(n) fotos")
    }

    private static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    /// Puts the line on the right screen after a placement change.
    private func moveLine() {
        panel.placeOnScreen()
        updateCapacity()
        refresh()
    }

    /// Moving the slider brings the line down, so you see where it will hang.
    private func setTopOffset(_ value: CGFloat) {
        Placement.topOffset = value.rounded()
        line.topOffset = Placement.topOffset
        panel.placeOnScreen(panel.screen)
        wanted = true
        refresh()
        reveal(pinned: true)
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting", "No se pudo cambiar el inicio de sesión")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.",
                                      "Mueve Tendedero a la carpeta Aplicaciones y vuelve a intentarlo.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

/// A labelled slider inside a menu, laid out like the menu's own items.
final class SliderMenuView: NSView {
    private let onChange: (Double) -> Void
    private let unit: String
    private let format: ((Double) -> String)?
    private let slider: NSSlider
    private let valueLabel = NSTextField(labelWithString: "")

    init(title: String, value: Double, range: ClosedRange<Double>, unit: String = " pt",
         format: ((Double) -> String)? = nil, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.unit = unit
        self.format = format
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 48))

        let label = NSTextField(labelWithString: title)
        label.font = .menuFont(ofSize: 0)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed)

        for view in [label, valueLabel, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
        ])
        showValue()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func showValue() {
        valueLabel.stringValue = format?(slider.doubleValue) ?? "\(Int(slider.doubleValue.rounded()))\(unit)"
    }

    @objc private func changed() {
        showValue()
        onChange(slider.doubleValue)
    }
}
