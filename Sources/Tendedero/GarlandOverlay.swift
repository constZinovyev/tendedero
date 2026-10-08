import AppKit
import Combine

/// Shows the garlands: one transparent window per screen, each drawing every
/// garland that crosses it. Outside of editing the windows ignore the mouse
/// completely, so they cost nothing and never get in the way.
@MainActor
final class GarlandController {
    let store = Garlands()
    private var overlays: [GarlandOverlay] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildOverlays() }
        }
        rebuildOverlays()
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { GarlandOverlay(screen: $0, store: store) }
        refresh()
    }

    /// Garlands hang on the screens the line may come down on.
    func refresh() {
        // objectWillChange fires before the change lands; draw after it.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let show = self.store.visible || self.store.editing
            for overlay in self.overlays {
                if show && Placement.allows(overlay.home) && (!self.store.isEmpty || self.store.editing) {
                    overlay.refreshGarlands()
                    overlay.orderFrontRegardless()
                } else {
                    overlay.orderOut(nil)
                }
            }
        }
    }

    func toggleEditing() {
        store.editing.toggle()
        if store.editing, let overlay = overlays.first(where: { $0.home == Self.lineScreen }) {
            overlay.makeKey()
        }
    }

    func add() {
        store.editing = true
        store.add(on: Self.lineScreen)
    }

    func addCandles() {
        store.editing = true
        store.addCandles(on: Self.lineScreen)
    }

    /// The screen the line hangs on now, or would come down on.
    private static var lineScreen: NSScreen? {
        Placement.mainScreenOnly ? Placement.mainScreen : LinePanel.screenUnderPointer()
    }

    /// The Garlands submenu of the status item.
    func menu() -> NSMenu {
        let menu = NSMenu()
        let show = ClosureMenuItem(L("Show decorations", "Mostrar decoración")) { [weak self] in
            guard let self else { return }
            self.store.visible.toggle()
        }
        show.state = store.visible ? .on : .off
        show.isEnabled = !store.isEmpty
        menu.addItem(show)

        let edit = ClosureMenuItem(store.editing ? L("Done editing", "Terminar edición")
                                                 : L("Edit decorations…", "Editar decoración…")) { [weak self] in
            self?.toggleEditing()
        }
        menu.addItem(edit)
        menu.addItem(ClosureMenuItem(L("Add garland", "Añadir guirnalda")) { [weak self] in self?.add() })
        if store.candles == nil {
            menu.addItem(ClosureMenuItem(L("Add candles", "Añadir velas")) { [weak self] in self?.addCandles() })
        } else {
            menu.addItem(ClosureMenuItem(L("Remove candles", "Quitar velas")) { [weak self] in self?.store.candles = nil })
        }

        menu.addItem(.separator())
        let allOn = ClosureMenuItem(L("All lights on", "Encender todas")) { [weak self] in self?.store.setAll(.on) }
        allOn.isEnabled = !store.items.isEmpty
        menu.addItem(allOn)
        let allOff = ClosureMenuItem(L("All lights off", "Apagar todas")) { [weak self] in self?.store.setAll(.off) }
        allOff.isEnabled = !store.items.isEmpty
        menu.addItem(allOff)

        menu.addItem(.separator())
        let look = NSMenuItem(title: L("Garland appearance", "Aspecto de las guirnaldas"), action: nil, keyEquivalent: "")
        look.submenu = appearanceMenu()
        menu.addItem(look)
        let candleLook = NSMenuItem(title: L("Candle appearance", "Aspecto de las velas"), action: nil, keyEquivalent: "")
        candleLook.submenu = candleMenu()
        menu.addItem(candleLook)
        return menu
    }

    /// The candles' wax, size, halo, flicker and warmth.
    private func candleMenu() -> NSMenu {
        let menu = NSMenu()
        let store = store
        let style = store.candleStyle
        for wax in CandleStyle.Wax.allCases {
            let item = ClosureMenuItem(wax.title) { store.candleStyle.wax = wax }
            item.state = style.wax == wax ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>,
                    format: @escaping (Double) -> String, set: @escaping (inout CandleStyle, Double) -> Void) {
            let item = NSMenuItem()
            item.view = SliderMenuView(title: title, value: value, range: range, format: format) { v in
                set(&store.candleStyle, v)
            }
            menu.addItem(item)
        }
        slider(L("Size", "Tamaño"), Double(style.size), 4...24, format: { "\(Int($0.rounded())) pt" }) { $0.size = CGFloat($1) }
        slider(L("Halo", "Halo"), Double(style.halo) * 100, 0...150, format: { "\(Int($0.rounded()))%" }) { $0.halo = CGFloat($1 / 100) }
        slider(L("Flicker", "Parpadeo"), Double(style.flicker) * 100, 0...150, format: { "\(Int($0.rounded()))%" }) { $0.flicker = CGFloat($1 / 100) }
        slider(L("Warmth", "Calidez"), Double(style.warmth), 18...48, format: { "\(Int($0.rounded()))°" }) { $0.warmth = CGFloat($1) }

        menu.addItem(.separator())
        let reset = ClosureMenuItem(L("Reset to defaults", "Restablecer")) { store.candleStyle = .defaults }
        reset.isEnabled = style != .defaults
        menu.addItem(reset)
        return menu
    }

    /// The look of every garland: the bulb design and its details. Changes
    /// show on the screen at once, so the garlands come out while you tune.
    private func appearanceMenu() -> NSMenu {
        let menu = NSMenu()
        let store = store
        let style = store.style

        for design in GarlandStyle.Design.allCases {
            let item = ClosureMenuItem(design.title) { store.style.design = design }
            item.state = style.design == design ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        func slider(_ title: String, _ value: CGFloat, _ range: ClosedRange<Double>, unit: String = " pt",
                    scale: Double = 1, format: ((Double) -> String)? = nil,
                    set: @escaping (inout GarlandStyle, CGFloat) -> Void) {
            let item = NSMenuItem()
            item.view = SliderMenuView(title: title, value: Double(value) * scale, range: range, unit: unit,
                                       format: format) { v in
                set(&store.style, CGFloat(v / scale))
            }
            menu.addItem(item)
        }

        slider(L("Bulb size", "Tamaño"), style.bulbSize, 20...100, scale: 10,
               format: { String(format: "%.1f pt", $0 / 10) }) { $0.bulbSize = $1 }
        slider(L("Glass clarity", "Transparencia del cristal"), style.glassClarity, 0...100, unit: "%", scale: 100) { $0.glassClarity = $1 }
        slider(L("Filament", "Filamento"), style.filament, 10...100, unit: "%", scale: 100) { $0.filament = $1 }
        slider(L("Halo size", "Tamaño del halo"), style.haloSize, 0...80, scale: 10,
               format: { String(format: "%.1f×", $0 / 10) }) { $0.haloSize = $1 }
        slider(L("Halo strength", "Intensidad del halo"), style.haloStrength, 0...150, unit: "%", scale: 100) { $0.haloStrength = $1 }
        slider(L("Warmth", "Calidez"), style.warmth, 18...52, unit: "°") { $0.warmth = $1 }
        menu.addItem(.separator())

        let strands = NSMenuItem(title: L("Wire strands", "Hilos del cable"), action: nil, keyEquivalent: "")
        let strandMenu = NSMenu()
        for n in 1...3 {
            let item = ClosureMenuItem("\(n)") { store.style.strands = n }
            item.state = style.strands == n ? .on : .off
            strandMenu.addItem(item)
        }
        strands.submenu = strandMenu
        menu.addItem(strands)
        slider(L("Wire thickness", "Grosor del cable"), style.wireWidth, 5...30, scale: 10,
               format: { String(format: "%.1f pt", $0 / 10) }) { $0.wireWidth = $1 }
        slider(L("Twist", "Torsión"), style.twistPitch, 6...60) { $0.twistPitch = $1 }
        slider(L("Lead length", "Largo del colgante"), style.lead, 0...14) { $0.lead = $1 }

        menu.addItem(.separator())
        let reset = ClosureMenuItem(L("Reset to defaults", "Restablecer")) { store.style = .defaults }
        reset.isEnabled = style != .defaults
        menu.addItem(reset)
        return menu
    }
}

/// The window over one screen.
@MainActor
final class GarlandOverlay: NSPanel {
    let store: Garlands
    /// The screen this window covers.
    let home: NSScreen
    private let view: GarlandEditView

    init(screen: NSScreen, store: Garlands) {
        self.store = store
        home = screen
        view = GarlandEditView(store: store, screenFrame: screen.frame)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = view
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { store.editing }
    override var canBecomeMain: Bool { false }

    /// While editing, the garlands float over everything and take the mouse,
    /// so they can be reached even when windows cover them.
    func refreshGarlands() {
        let editing = store.editing
        ignoresMouseEvents = !editing
        level = editing ? .floating : Self.background
        view.reload()
    }

    /// Just above the wallpaper: under the desktop icons, every window and
    /// the line with its photos, even when the line itself hangs behind windows.
    static let background = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)

    override func cancelOperation(_ sender: Any?) {
        if store.editing { store.editing = false }
    }
}

/// Draws the garlands and, while editing, lets you shape them: drag an end
/// to move it, the middle handle to change the sag, the wire to move the
/// whole garland. Click a bulb to switch it off or on; right click a garland
/// for its settings.
@MainActor
final class GarlandEditView: NSView {
    private let store: Garlands
    private let screenFrame: CGRect
    private let layers = GarlandLayers()
    private let candleLayers = CandleLayers()
    private let handles = CAShapeLayer()
    private let doneButton = NSButton()

    private enum Target {
        case start(UUID), end(UUID), sag(UUID), wire(UUID, CGPoint, CGPoint), bulb(UUID, Int)
        case candles(CGPoint)
    }
    private var target: Target?
    private var downPoint: CGPoint = .zero
    private var moved = false

    private static let handleRadius: CGFloat = 7
    private static let grab: CGFloat = 12

    init(store: Garlands, screenFrame: CGRect) {
        self.store = store
        self.screenFrame = screenFrame
        super.init(frame: CGRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
        layer?.addSublayer(candleLayers.root)
        layer?.addSublayer(layers.root)
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.controlAccentColor.cgColor
        handles.lineWidth = 2
        handles.shadowOpacity = 0.3
        handles.shadowRadius = 2
        handles.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(handles)

        doneButton.title = L("Done", "Listo")
        doneButton.bezelStyle = .push
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.sizeToFit()
        addSubview(doneButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        doneButton.frame.origin = CGPoint(x: (bounds.width - doneButton.frame.width) / 2,
                                          y: bounds.height - doneButton.frame.height - 40)
    }

    @objc private func done() { store.editing = false }

    func reload() {
        let scale = window?.backingScaleFactor ?? 2
        layers.render(store.items, style: store.style, origin: screenFrame.origin, scale: scale)
        candleLayers.render(store.candles, style: store.candleStyle, origin: screenFrame.origin, scale: scale)
        doneButton.isHidden = !store.editing || !screenFrame.contains(NSEvent.mouseLocation) && NSScreen.screens.count > 1
        drawHandles()
    }

    private func drawHandles() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard store.editing else {
            handles.path = nil
            return
        }
        let path = CGMutablePath()
        let r = Self.handleRadius
        for g in store.items {
            for p in [g.start, g.end] {
                path.addEllipse(in: CGRect(x: p.x - screenFrame.minX - r, y: p.y - screenFrame.minY - r, width: r * 2, height: r * 2))
            }
            let m = GarlandGeometry.middle(of: g)
            let s = r * 0.8
            path.addRoundedRect(in: CGRect(x: m.x - screenFrame.minX - s, y: m.y - screenFrame.minY - s, width: s * 2, height: s * 2),
                                cornerWidth: 2, cornerHeight: 2)
        }
        handles.path = path
    }

    /// A point in this view to global screen coordinates.
    private func global(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x + screenFrame.minX, y: p.y + screenFrame.minY)
    }

    /// What is under the pointer, handles first, the topmost garland first.
    private func hit(_ p: CGPoint) -> Target? {
        let style = store.style
        for g in store.items.reversed() {
            if hypot(g.start.x - p.x, g.start.y - p.y) <= Self.grab { return .start(g.id) }
            if hypot(g.end.x - p.x, g.end.y - p.y) <= Self.grab { return .end(g.id) }
            let m = GarlandGeometry.middle(of: g)
            if hypot(m.x - p.x, m.y - p.y) <= Self.grab { return .sag(g.id) }
        }
        for g in store.items.reversed() {
            let geo = GarlandGeometry(g)
            for (i, b) in geo.bulbPositions(spacing: g.spacing).enumerated() {
                let c = style.bulbCenter(below: b)
                if hypot(c.x - p.x, c.y - p.y) <= style.bulbSize * 1.3 + 4 { return .bulb(g.id, i) }
            }
            if geo.distance(to: p) <= 8 { return .wire(g.id, g.start, g.end) }
        }
        if let set = store.candles, store.candleStyle.bounds(at: set.position).contains(p) {
            return .candles(set.position)
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard store.editing else { return }
        downPoint = global(event)
        moved = false
        target = hit(downPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        guard store.editing, let target else { return }
        let p = global(event)
        if hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 { moved = true }
        guard moved else { return }
        // Saved on mouse up; while dragging only the drawing changes.
        switch target {
        case .start(let id):
            store.update(id, save: false) { $0.start = p }
        case .end(let id):
            store.update(id, save: false) { $0.end = p }
        case .sag(let id):
            // The middle handle moves down for depth and sideways to shift
            // the lowest part towards one end.
            store.update(id, save: false) { g in
                g.sag = (g.start.y + g.end.y) / 2 - p.y
                g.shift = p.x - (g.start.x + g.end.x) / 2
            }
        case .bulb(let id, _):
            // Dragging from a bulb moves the whole garland, like the wire.
            guard let g = store.items.first(where: { $0.id == id }) else { return }
            self.target = .wire(id, g.start, g.end)
            mouseDragged(with: event)
        case .candles(let start):
            store.candles?.position = CGPoint(x: start.x + p.x - downPoint.x, y: start.y + p.y - downPoint.y)
        case .wire(let id, let s, let e):
            let dx = p.x - downPoint.x, dy = p.y - downPoint.y
            store.update(id, save: false) { g in
                g.start = CGPoint(x: s.x + dx, y: s.y + dy)
                g.end = CGPoint(x: e.x + dx, y: e.y + dy)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard store.editing else { return }
        if !moved, case .bulb(let id, let i) = target {
            store.toggleBulb(i, of: id)
        } else if moved {
            store.save()
        }
        target = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard store.editing else { return }
        let p = global(event)
        let id: UUID?
        switch hit(p) {
        case .start(let g), .end(let g), .sag(let g), .wire(let g, _, _), .bulb(let g, _): id = g
        case .candles:
            let menu = NSMenu()
            let store = store
            menu.addItem(ClosureMenuItem(L("Remove candles", "Quitar velas")) { store.candles = nil })
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        case nil: id = nil
        }
        guard let id, let g = store.items.first(where: { $0.id == id }) else { return }
        NSMenu.popUpContextMenu(menu(for: g), with: event, for: self)
    }

    private func menu(for g: Garland) -> NSMenu {
        let menu = NSMenu()
        let store = store
        let id = g.id
        for mode in Garland.Mode.allCases {
            let item = ClosureMenuItem(mode.title) { store.update(id) { $0.mode = mode } }
            item.state = g.mode == mode ? .on : .off
            menu.addItem(item)
        }
        let allBulbs = ClosureMenuItem(L("Turn every bulb back on", "Volver a encender todas las bombillas")) {
            store.update(id) { $0.bulbsOff = [] }
        }
        allBulbs.isEnabled = !g.bulbsOff.isEmpty
        menu.addItem(allBulbs)
        menu.addItem(.separator())

        let spacing = NSMenuItem()
        spacing.view = SliderMenuView(
            title: L("Bulb spacing", "Separación"),
            value: Double(g.spacing),
            range: Double(Garland.spacingRange.lowerBound)...Double(Garland.spacingRange.upperBound)
        ) { value in store.update(id) { $0.spacing = CGFloat(value) } }
        menu.addItem(spacing)

        let brightness = NSMenuItem()
        brightness.view = SliderMenuView(
            title: L("Brightness", "Brillo"), value: g.brightness * 100, range: 10...100, unit: "%"
        ) { value in store.update(id) { $0.brightness = value / 100 } }
        menu.addItem(brightness)

        let speed = NSMenuItem()
        speed.view = SliderMenuView(
            title: L("Animation speed", "Velocidad"), value: g.speed * 100,
            range: Garland.speedRange.lowerBound * 100...Garland.speedRange.upperBound * 100, unit: "%"
        ) { value in store.update(id) { $0.speed = value / 100 } }
        menu.addItem(speed)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Delete garland", "Eliminar guirnalda")) { store.remove(id) })
        return menu
    }
}
