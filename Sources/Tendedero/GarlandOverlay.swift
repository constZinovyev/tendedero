import AppKit
import Combine

/// One decoration on the desktop: a garland, or the candles.
enum Decor: Hashable {
    case garland(UUID)
    case candles
}

/// Shows the decorations. Each one gets its own small window, just big
/// enough for it, so macOS itself can tell when that one is covered by other
/// windows, on another Space or on a sleeping display; then its animation
/// pauses. The windows sit just above the desktop icons, under every other
/// window and under the line. They let the mouse through except right over a
/// wire, a bulb or the candles, which is checked only when the mouse moves.
@MainActor
final class GarlandController {
    let store = Garlands()
    /// The line's window, so the decorations always stay under it.
    var lineWindow: (() -> NSWindow?)?

    private var windows: [Decor: DecorWindow] = [:]
    private var refreshPending = false
    private var cancellables = Set<AnyCancellable>()
    private var monitors: [Any] = []
    private lazy var donePanel = DonePanel { [weak self] in self?.store.editing = false }

    init() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Only when the mouse moves: decide which decoration, if any, should
        // catch it. Nothing runs while the mouse is still.
        let moved: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: moved) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { moved($0); return $0 }) {
            monitors.append(m)
        }
        refresh()
        scheduleFish()
    }

    /// Redraws after changes, once however many came in meanwhile (a drag
    /// sends many). objectWillChange fires before a change lands, so this
    /// waits for the next turn of the run loop.
    func refresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.sync()
        }
    }

    private func sync() {
        let show = store.visible || store.editing
        var wanted: [Decor] = []
        if show {
            wanted = store.items.map { .garland($0.id) }
            if store.candles != nil { wanted.append(.candles) }
        }
        // Fish go with their garland, and while the garlands are edited.
        fish = store.editing ? [:] : fish.filter { id, _ in store.items.contains { $0.id == id } }
        for (key, window) in windows where !wanted.contains(key) {
            window.orderOut(nil)
            windows[key] = nil
        }
        let line = lineWindow?()
        for key in wanted {
            let window = windows[key] ?? DecorWindow(decor: key, store: store, controller: self)
            windows[key] = window
            guard let frame = window.decorView.contentFrame(),
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                    ?? NSScreen.main,
                  Placement.allows(screen) else {
                window.orderOut(nil)
                continue
            }
            window.show(in: frame, editing: store.editing, below: line)
        }
        if store.editing { donePanel.present(on: Self.lineScreen) } else { donePanel.orderOut(nil) }
        mouseMoved()
    }

    private var lastMouse: (point: CGPoint, time: CFTimeInterval)?

    /// Also called by a decoration's own window while the pointer is over
    /// it: there it catches the mouse, and macOS no longer reports the
    /// moves to the monitors above.
    func mouseMoved() {
        let p = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        // How fast the pointer moves, in points a second: the air it stirs.
        var velocity = CGVector.zero
        if let last = lastMouse, now - last.time > 0.001, now - last.time < 0.25 {
            let dt = now - last.time
            velocity = CGVector(dx: (p.x - last.point.x) / dt, dy: (p.y - last.point.y) / dt)
        }
        lastMouse = (p, now)
        for window in windows.values where window.isVisible {
            window.catchMouse(window.decorView.hits(p))
            // Uncovered just now: the notice may come late, so look.
            window.decorView.setPaused(!window.occlusionState.contains(.visible))
            window.decorView.feelAir(at: p, velocity: velocity)
        }
        touchBulbs()
    }

    /// While the pointer rests on a bulb it keeps that bulb gently swaying,
    /// touching it again every so often; nothing runs once it leaves.
    private var touchTimer: Timer?

    private func touchBulbs() {
        let p = NSEvent.mouseLocation
        var touching = false
        for window in windows.values where window.isVisible {
            if window.decorView.touchBulb(at: p) { touching = true }
        }
        if touching, touchTimer == nil {
            let timer = Timer(timeInterval: 0.32, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.touchBulbs() }
            }
            RunLoop.main.add(timer, forMode: .common)
            touchTimer = timer
        } else if !touching {
            touchTimer?.invalidate()
            touchTimer = nil
        }
    }

    // MARK: Fish

    /// Bulbs with a fish hanging in their place, by garland.
    private(set) var fish: [UUID: Set<Int>] = [:]
    private var fishTimer: Timer?
    /// Told when a fish has been hung, so a gull can come for it.
    var onFish: (() -> Void)?
    private static let maxFish = 2

    private var fishCount: Int { fish.values.reduce(0) { $0 + $1.count } }

    /// A fish every one to two and a half minutes, at most two hanging:
    /// more often than the gulls come, so they find some waiting.
    private func scheduleFish() {
        fishTimer?.invalidate()
        let t = Timer(timeInterval: .random(in: 60...150), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hangFish()
                self.scheduleFish()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fishTimer = t
    }

    /// One bulb, on a garland on show, turns into a fish. Returns whether
    /// one did.
    @discardableResult
    func hangFish() -> Bool {
        guard !store.editing, fishCount < Self.maxFish else { return false }
        var choices: [(UUID, Int, DecorView)] = []
        for (key, window) in windows where window.isVisible {
            guard case .garland(let id) = key else { continue }
            let taken = fish[id] ?? []
            // Not right at the ends, where the gull could not reach well.
            let n = window.decorView.bulbCount
            guard n > 2 else { continue }
            for i in 1..<(n - 1) where !taken.contains(i) && !taken.contains(i - 1) && !taken.contains(i + 1) {
                choices.append((id, i, window.decorView))
            }
        }
        guard let (id, i, view) = choices.randomElement() else { return false }
        fish[id, default: []].insert(i)
        view.setFish(fish[id] ?? [], animated: true)
        onFish?()
        return true
    }

    /// The fish on show, in screen coordinates.
    func fishSpots() -> [(id: UUID, index: Int, point: CGPoint)] {
        var result: [(id: UUID, index: Int, point: CGPoint)] = []
        for (id, indices) in fish where !indices.isEmpty {
            guard let window = windows[.garland(id)], window.isVisible else { continue }
            for (i, p) in window.decorView.fishPoints() { result.append((id, i, p)) }
        }
        return result
    }

    /// A gull takes the fish: the bulb comes back. Returns whether it was there.
    func snatchFish(_ id: UUID, _ index: Int) -> Bool {
        guard fish[id]?.contains(index) == true else { return false }
        fish[id]?.remove(index)
        windows[.garland(id)]?.decorView.snatchFish(index)
        return true
    }

    // MARK: Birds

    /// Air moving past the decorations from anything but the pointer: a
    /// bird's wings. `p` is in screen coordinates.
    func feelAir(at p: CGPoint, velocity: CGVector) {
        for window in windows.values where window.isVisible {
            window.decorView.feelAir(at: p, velocity: velocity)
        }
    }

    /// The garland wires on show, in screen coordinates, for a bird to sit on.
    func wires() -> [(id: UUID, points: [CGPoint])] {
        guard !store.editing else { return [] }
        return store.items.compactMap { g in
            guard windows[.garland(g.id)]?.isVisible == true else { return nil }
            return (g.id, GarlandGeometry(g).points)
        }
    }

    /// The top of the candle flames, if the candles are on show.
    var candleTop: CGPoint? {
        guard let set = store.candles, windows[.candles]?.isVisible == true else { return nil }
        let r = store.candleStyle.bounds(at: set.position)
        return CGPoint(x: r.midX, y: r.maxY)
    }

    /// A bird on a garland's wire at `p` (screen coordinates) pulls it down.
    func bend(_ id: UUID, at p: CGPoint, depth: CGFloat) {
        windows[.garland(id)]?.decorView.bend(at: p, depth: depth)
    }

    func toggleEditing() {
        store.editing.toggle()
    }

    func add() {
        store.editing = true
        store.add(on: Self.lineScreen)
    }

    func addCandles() {
        store.addCandles(on: Self.lineScreen)
    }

    /// The screen the line hangs on now, or would come down on.
    static var lineScreen: NSScreen? {
        Placement.mainScreenOnly ? Placement.mainScreen : LinePanel.screenUnderPointer()
    }

    // MARK: Menus

    /// The Decorations submenu of the status item.
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
                                                 : L("Edit objects…", "Editar objetos…")) { [weak self] in
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
    func candleMenu() -> NSMenu {
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
        slider(L("Size", "Tamaño"), Double(style.size), 6...30, format: { "\(Int($0.rounded())) pt" }) { $0.size = CGFloat($1) }
        slider(L("Thickness", "Grosor"), Double(style.thickness) * 100, 70...140, format: { "\(Int($0.rounded()))%" }) { $0.thickness = CGFloat($1 / 100) }
        slider(L("Closeness", "Cercanía"), Double(style.tightness) * 100, 60...120, format: { "\(Int($0.rounded()))%" }) { $0.tightness = CGFloat($1 / 100) }
        slider(L("Drips", "Chorreones"), Double(style.drips), 0...6, format: { "\(Int($0.rounded()))" }) { $0.drips = Int($1.rounded()) }
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
    func appearanceMenu() -> NSMenu {
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

/// The small window around one decoration.
@MainActor
final class DecorWindow: NSPanel {
    let decorView: DecorView
    private let store: Garlands

    /// Just above the desktop icons, so the decorations can be clicked, and
    /// under every ordinary window.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    init(decor: Decor, store: Garlands, controller: GarlandController) {
        self.store = store
        decorView = DecorView(decor: decor, store: store, controller: controller)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Over the candles the window takes the mouse; keep its moves coming
        // so the air keeps stirring right over the flames.
        acceptsMouseMovedEvents = true
        level = Self.level
        contentView = decorView
        // Covered by other windows, on another Space or on a sleeping
        // display: nothing to see, so nothing to animate.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                               object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.decorView.setPaused(!self.occlusionState.contains(.visible))
            }
        }
    }

    override var canBecomeKey: Bool { store.editing }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if store.editing { store.editing = false }
    }

    /// While editing, every decoration floats over the windows so it can be
    /// reached even where they cover it.
    func show(in frame: CGRect, editing: Bool, below line: NSWindow?) {
        if self.frame != frame { setFrame(frame, display: false) }
        level = editing ? .floating : Self.level
        decorView.reload()
        if !isVisible { orderFrontRegardless() }
        if !editing, let line, line.isVisible, line.level == level {
            order(.below, relativeTo: line.windowNumber)
        }
    }

    func catchMouse(_ catching: Bool) {
        if ignoresMouseEvents == catching { ignoresMouseEvents = !catching }
    }
}

/// Draws one decoration and handles the mouse on it. The candles can be
/// dragged any time. A garland is shaped in edit mode: drag an end, the
/// middle handle (down for depth, sideways to shift the lowest point) or
/// the wire to move it; click a bulb to switch it off or on. Right click
/// either for its settings.
@MainActor
final class DecorView: NSView {
    let decor: Decor
    private let store: Garlands
    private weak var controller: GarlandController?
    private let garlandLayers = GarlandLayers()
    private let candleLayers = CandleLayers()
    private let handles = CAShapeLayer()
    private var geometry: (garland: Garland, geo: GarlandGeometry, bulbs: [CGPoint])?

    private enum Target {
        case start, end, sag, wire(CGPoint, CGPoint), bulb(Int), candles(CGPoint)
    }
    private var target: Target?
    private var downPoint: CGPoint = .zero
    private var moved = false

    private static let handleRadius: CGFloat = 7
    private static let grab: CGFloat = 12
    /// How far a hand can pull the wire down, and up against its ends.
    private static let pullDown: CGFloat = 36
    private static let pullUp: CGFloat = 16

    /// Out of edit mode the wire can be taken and pulled; let go, it bounces.
    private var pulling = false
    private var heldFrom: CGFloat = 0

    init(decor: Decor, store: Garlands, controller: GarlandController) {
        self.decor = decor
        self.store = store
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(candleLayers.root)
        layer?.addSublayer(garlandLayers.root)
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.controlAccentColor.cgColor
        handles.lineWidth = 2
        handles.shadowOpacity = 0.3
        handles.shadowRadius = 2
        handles.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(handles)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// While the pointer is over a wire, a bulb or the candles, this window
    /// catches the mouse and the global monitors fall silent. A tracking
    /// area that is always active keeps the moves coming even though
    /// Tendedero is not the active app, so the air never stops stirring.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.mouseMoved()
    }

    private var garland: Garland? {
        guard case .garland(let id) = decor else { return nil }
        return store.items.first { $0.id == id }
    }

    /// The window's frame in screen coordinates: the decoration with room
    /// for its glow and, for a garland, its handles.
    func contentFrame() -> CGRect? {
        switch decor {
        case .candles:
            guard let set = store.candles else { return nil }
            let st = store.candleStyle
            return st.bounds(at: set.position).insetBy(dx: -st.size * 6, dy: -st.size * 6).integral
        case .garland:
            guard let g = garland else { return nil }
            let st = store.style
            let geo = GarlandGeometry(g)
            let xs = geo.points.map(\.x), ys = geo.points.map(\.y)
            let glow = st.bulbSize * st.haloSize + 6
            let margin = max(glow, Self.grab) + 4
            // Room below for the wire pulled down by a hand.
            let rect = CGRect(x: (xs.min() ?? 0) - margin,
                              y: (ys.min() ?? 0) - st.lightDrop - glow - st.bulbSize * 2 - Self.pullDown,
                              width: (xs.max() ?? 0) - (xs.min() ?? 0) + margin * 2, height: 0)
            let top = max(ys.max() ?? 0, GarlandGeometry.middle(of: g).y) + margin
            return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: top - rect.minY).integral
        }
    }

    /// Freezes or resumes every animation in this window.
    /// Pausing freezes the current frame; resuming puts the layer back on
    /// the system clock. The loops just carry on from there: shifting the
    /// clock by the time spent paused would make every animation added
    /// later start that far in the future, so after a night behind other
    /// windows the flames would stand still.
    func setPaused(_ paused: Bool) {
        guard let layer, (layer.speed == 0) != paused else { return }
        if paused {
            layer.timeOffset = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
        } else {
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
        }
    }

    func reload() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        let origin = window.frame.origin
        switch decor {
        case .candles:
            candleLayers.render(store.candles, style: store.candleStyle, origin: origin, size: bounds.size, scale: scale)
            geometry = nil
        case .garland:
            guard let g = garland else { return }
            garlandLayers.render([g], style: store.style, origin: origin, size: bounds.size, scale: scale)
            garlandLayers.setFish(controller?.fish[g.id] ?? [], animated: false)
            let geo = GarlandGeometry(g)
            geometry = (g, geo, geo.bulbPositions(spacing: g.spacing).map { store.style.bulbCenter(below: $0) })
        }
        drawHandles(origin: origin)
    }

    private func drawHandles(origin: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard store.editing, let g = garland else {
            handles.path = nil
            return
        }
        let path = CGMutablePath()
        let r = Self.handleRadius
        for p in [g.start, g.end] {
            path.addEllipse(in: CGRect(x: p.x - origin.x - r, y: p.y - origin.y - r, width: r * 2, height: r * 2))
        }
        let m = GarlandGeometry.middle(of: g)
        let s = r * 0.8
        path.addRoundedRect(in: CGRect(x: m.x - origin.x - s, y: m.y - origin.y - s, width: s * 2, height: s * 2),
                            cornerWidth: 2, cornerHeight: 2)
        handles.path = path
    }

    /// What is under a point in screen coordinates, or nil to let the
    /// click through to whatever is below.
    private func hit(_ p: CGPoint) -> Target? {
        switch decor {
        case .candles:
            guard let set = store.candles, store.candleStyle.bounds(at: set.position).contains(p) else { return nil }
            return .candles(set.position)
        case .garland:
            guard let geometry else { return nil }
            let g = geometry.garland, geo = geometry.geo, bulbs = geometry.bulbs
            if store.editing {
                if hypot(g.start.x - p.x, g.start.y - p.y) <= Self.grab { return .start }
                if hypot(g.end.x - p.x, g.end.y - p.y) <= Self.grab { return .end }
                let m = GarlandGeometry.middle(of: g)
                if hypot(m.x - p.x, m.y - p.y) <= Self.grab { return .sag }
            }
            let reach = store.style.bulbSize * 1.3 + 4
            if let i = bulbs.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= reach }) { return .bulb(i) }
            if geo.distance(to: p) <= 8 { return .wire(g.start, g.end) }
            return nil
        }
    }

    func hits(_ p: CGPoint) -> Bool {
        target != nil || hit(p) != nil
    }

    /// The pointer on a bulb of this garland touches it. Returns whether it
    /// is on one.
    func touchBulb(at p: CGPoint) -> Bool {
        guard case .garland = decor, !store.editing, target == nil, case .bulb(let i) = hit(p) else { return false }
        garlandLayers.touch(bulb: i)
        return true
    }

    var bulbCount: Int { geometry?.bulbs.count ?? 0 }

    func setFish(_ wanted: Set<Int>, animated: Bool) {
        garlandLayers.setFish(wanted, animated: animated)
    }

    /// Where the fish on this garland hang, by bulb, in screen coordinates.
    func fishPoints() -> [Int: CGPoint] {
        guard let window else { return [:] }
        return garlandLayers.fishPoints().mapValues { CGPoint(x: $0.x + window.frame.minX, y: $0.y + window.frame.minY) }
    }

    func snatchFish(_ i: Int) {
        garlandLayers.snatchFish(i)
    }

    func bend(at p: CGPoint, depth: CGFloat) {
        guard let window else { return }
        garlandLayers.bend(at: CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY), depth: depth)
    }

    /// The pointer moving past the candles stirs the air around them.
    func feelAir(at p: CGPoint, velocity: CGVector) {
        guard let window, target == nil else { return }
        let local = CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY)
        switch decor {
        case .candles: candleLayers.feelAir(at: local, velocity: velocity)
        case .garland: if !store.editing { garlandLayers.feelAir(at: local, velocity: velocity) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = NSEvent.mouseLocation
        moved = false
        target = hit(downPoint)
        if case .candles = target { store.holdSaves = true }
        pulling = false
        if !store.editing, let window {
            switch target {
            case .wire, .bulb:
                pulling = true
                heldFrom = garlandLayers.grab(at: CGPoint(x: downPoint.x - window.frame.minX,
                                                          y: downPoint.y - window.frame.minY))
            default: break
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let target else { return }
        let p = NSEvent.mouseLocation
        if hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 { moved = true }
        guard moved else { return }
        let dx = p.x - downPoint.x, dy = p.y - downPoint.y
        if pulling {
            // It gives easily at first and harder the farther it goes.
            let raw = heldFrom - dy
            let limit = raw > 0 ? Self.pullDown : Self.pullUp
            garlandLayers.pull(depth: limit * tanh(raw / limit))
            return
        }
        if case .candles(let start) = target {
            store.candles?.position = CGPoint(x: start.x + dx, y: start.y + dy)
            return
        }
        // A garland only changes shape in edit mode. Saved on mouse up.
        guard store.editing, case .garland(let id) = decor else { return }
        switch target {
        case .start:
            store.update(id, save: false) { $0.start = p }
        case .end:
            store.update(id, save: false) { $0.end = p }
        case .sag:
            store.update(id, save: false) { g in
                g.sag = (g.start.y + g.end.y) / 2 - p.y
                g.shift = p.x - (g.start.x + g.end.x) / 2
            }
        case .bulb:
            // Dragging from a bulb moves the whole garland, like the wire.
            guard let g = garland else { return }
            self.target = .wire(g.start, g.end)
            mouseDragged(with: event)
        case .wire(let s, let e):
            store.update(id, save: false) { g in
                g.start = CGPoint(x: s.x + dx, y: s.y + dy)
                g.end = CGPoint(x: e.x + dx, y: e.y + dy)
            }
        case .candles:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if pulling {
            pulling = false
            garlandLayers.release()
            target = nil
            return
        }
        if store.holdSaves {
            store.holdSaves = false
            store.saveCandles()
        }
        if store.editing, !moved, case .bulb(let i) = target, case .garland(let id) = decor {
            store.toggleBulb(i, of: id)
        } else if moved, case .garland = decor {
            store.save()
        }
        target = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        guard hit(NSEvent.mouseLocation) != nil else { return }
        let menu: NSMenu
        switch decor {
        case .candles: menu = candleMenu()
        case .garland: guard let g = garland else { return }; menu = garlandMenu(g)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func candleMenu() -> NSMenu {
        let menu = controller?.candleMenu() ?? NSMenu()
        let store = store
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Remove candles", "Quitar velas")) { store.candles = nil })
        return menu
    }

    private func garlandMenu(_ g: Garland) -> NSMenu {
        let menu = NSMenu()
        let store = store
        let id = g.id
        menu.addItem(ClosureMenuItem(store.editing ? L("Done editing", "Terminar edición")
                                                   : L("Edit", "Editar")) { store.editing.toggle() })
        menu.addItem(.separator())
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

        if let controller {
            let look = NSMenuItem(title: L("Garland appearance", "Aspecto de las guirnaldas"), action: nil, keyEquivalent: "")
            look.submenu = controller.appearanceMenu()
            menu.addItem(look)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Delete garland", "Eliminar guirnalda")) { store.remove(id) })
        return menu
    }
}

/// A small floating bar with a Done button while editing. It also takes
/// Escape and Return.
@MainActor
final class DonePanel: NSPanel {
    private let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init(contentRect: CGRect(x: 0, y: 0, width: 240, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let glass = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        glass.material = .hudWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 12
        let label = NSTextField(labelWithString: L("Editing objects", "Editando objetos"))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.frame = CGRect(x: 14, y: 13, width: 140, height: 18)
        let button = NSButton(title: L("Done", "Listo"), target: nil, action: nil)
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        button.sizeToFit()
        button.frame.origin = CGPoint(x: 240 - button.frame.width - 8, y: (44 - button.frame.height) / 2)
        button.target = self
        button.action = #selector(done)
        glass.addSubview(label)
        glass.addSubview(button)
        contentView = glass
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onDone() }

    @objc private func done() { onDone() }

    func present(on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(CGPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 16))
        if !isVisible { makeKeyAndOrderFront(nil) }
    }
}
