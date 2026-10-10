import AppKit
import Combine
import os

let log = Logger(subsystem: "app.tendedero.Tendedero", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    /// Where it hangs, as a fraction of the line's width, so it keeps its
    /// spot on a screen of any size.
    var position: Double = 0.5
    var falling = false
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.position == b.position && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// The photo being slid along the line to a new spot.
    @Published private(set) var slidingID: UUID?
    /// Whether the line has slid down into view.
    @Published var revealed = false
    /// How far below the menu bar the line hangs.
    @Published var topOffset = Placement.topOffset

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:] {
        didSet { if hitRects != oldValue { hitRectsChanged() } }
    }
    /// While the line slides down or a photo moves, every card reports on
    /// each frame: the panel looks again once, after all of them.
    private var hitRectsChangePending = false
    private func hitRectsChanged() {
        guard !hitRectsChangePending else { return }
        hitRectsChangePending = true
        DispatchQueue.main.async { [weak self] in
            self?.hitRectsChangePending = false
            self?.onHitRectsChange?()
        }
    }
    /// Lets the panel decide again whether to catch the mouse when a photo
    /// appears or moves under a pointer that is standing still.
    var onHitRectsChange: (() -> Void)?

    /// The photo under the pointer, set by the panel as the pointer moves.
    /// SwiftUI's own hover only hears of the pointer once the panel catches
    /// the mouse, a move too late: a pointer that came to rest on a photo
    /// in one quick move left it unlit.
    @Published var hoveredID: UUID?

    /// The photo drawn at `p`, in the panel's coordinates with y down: the
    /// front one where photos overlap, as it swings and dips with the rope.
    /// `slack` widens each card by that much.
    func photo(at p: CGPoint, slack: CGFloat) -> UUID? {
        for item in items.reversed() where !item.falling {
            guard let rect = hitRects[item.id] else { continue }
            // The photo turns about the top of its clothespin.
            let pin = CGPoint(x: rect.midX, y: rect.minY - PeggedView.cardOffsetBelowTop)
            if rect.insetBy(dx: -slack, dy: -slack).contains(sway(item.id).atRest(p, pin: pin)) { return item.id }
        }
        return nil
    }

    /// Each photo's swing, played by Core Animation.
    private var sways: [UUID: Sway] = [:]
    func sway(_ id: UUID) -> Sway {
        if let s = sways[id] { return s }
        let s = Sway()
        sways[id] = s
        return s
    }
    /// A card's frame on screen as it hangs right now, from the panel.
    var cardScreenFrame: ((UUID) -> CGRect?)?

    /// The line's width in points, kept up to date by the panel.
    var width: CGFloat = 1440

    /// The occasional breeze that sways the photos. Each sway is drawn by
    /// SwiftUI frame by frame, so it can be turned off to save energy.
    var breezeOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "breezeOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "breezeOff") }
    }

    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"
    private let positionsKey = "peggedPositions"
    private var slideStart: Double = 0

    init() {
        restore()
        scheduleGust()
        rope.onGrab = { [weak self] x in self?.grabRope(at: x) }
        rope.onPull = { [weak self] dy in self?.pullRope(by: dy) }
        rope.onRelease = { [weak self] in self?.releaseRope() }
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, thumb: NSImage? = nil, quietly: Bool = false, flying: Bool = false,
              at position: Double? = nil) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = thumb ?? makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        item.position = clamped(position ?? freeSpot())
        items.append(item)
        save()
        if !quietly { play("Tink", volume: 0.35) }
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
            self?.sways[id] = nil
        }
    }

    func clear() {
        let live = items.filter { !$0.falling }
        for (n, item) in live.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(n)) { [weak self] in
                self?.drop(item.id, quietly: n > 0)
            }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Moving along the line

    /// The edges a pin can reach, so the card never hangs off the screen.
    private var margin: Double { min(0.45, Double((Layout.cardWidth / 2 + 12) / max(width, 1))) }

    private func clamped(_ position: Double) -> Double {
        min(max(position, margin), 1 - margin)
    }

    /// A new photo is pinned next to the last one, like on a real line. When
    /// there is no room left on the right, it goes into the widest gap.
    private func freeSpot() -> Double {
        let taken = items.filter { !$0.falling }.map(\.position).sorted()
        guard let last = taken.last else { return 0.5 }
        let step = Double(Layout.spacing / max(width, 1))
        if last + step <= 1 - margin { return last + step }
        let bounds = [margin] + taken + [1 - margin]
        var best = (gap: -1.0, spot: 0.5)
        for (a, b) in zip(bounds, bounds.dropFirst()) where b - a > best.gap {
            best = (b - a, (a + b) / 2)
        }
        return best.spot
    }

    func beginSlide(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        slideStart = item.position
        slidingID = id
    }

    /// Slides the photo by `dx` points from where the slide began.
    func slide(_ id: UUID, by dx: CGFloat) {
        guard slidingID == id, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].position = clamped(slideStart + Double(dx / max(width, 1)))
    }

    func endSlide() {
        guard let id = slidingID else { return }
        slidingID = nil
        bringToFront(id)
    }

    // MARK: Stacking

    /// Photos overlap in the order of the list: the last one is on top. The
    /// one you last touched comes to the front, like a window.
    func bringToFront(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i != items.count - 1 else { return }
        items.append(items.remove(at: i))
        save()
    }

    func sendToBack(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i != 0 else { return }
        items.insert(items.remove(at: i), at: 0)
        save()
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        if let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }

    /// A large look at the photo in the middle of the screen. The line stays
    /// as it is and no other app opens.
    func show(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        PhotoPreview.shared.show(item.url, thumb: item.thumb, from: { [weak self] in self?.cardScreenFrame?(id) }, tilt: item.tilt,
                                 on: LinePanel.screenUnderPointer())
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(item.url)
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    /// The photo falls at once; the file goes to the Trash in the
    /// background, which can take a moment the first time. Should that
    /// fail, the photo hangs again where it was.
    func trash(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if soundOn { Line.trashSound?.play() }
        drop(id, quietly: true)
        let url = item.url, position = item.position
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                log.notice("Trashed \(url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("Could not trash \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { [weak self] in
                    NSSound.beep()
                    self?.hang(url, quietly: true, at: position)
                }
            }
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID) {
        if isInInbox(id) { trash(id) } else { drop(id) }
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        Markup.shared.edit(item.url)
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let thumb = makeThumbnail(url) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let i = self.items.firstIndex(where: { $0.url == url && !$0.falling }) else { return }
                self.items[i].thumb = thumb
            }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: A bird on the line

    /// The rope as the panel draws it, so a bird sitting on it can bend it.
    let rope = RopeBend()

    /// A weight on the rope `x` points from its left end pulls it `depth`
    /// points down there, and the photos hanging nearby go down with it.
    /// A depth of zero straightens it.
    func bendRope(at x: CGFloat, depth: CGFloat) {
        rope.set(x: x, depth: depth)
        lowerPhotos()
    }

    /// Every photo goes down as far as the rope under its pin.
    private func lowerPhotos() {
        for item in items where !item.falling {
            sway(item.id).lower(rope.drop(at: CGFloat(item.position) * width, width: width))
        }
    }

    // MARK: A hand on the rope

    /// Whether the rope is in a hand right now.
    private(set) var ropeHeld = false
    private var bounce: Timer?

    /// Whether `p`, in the panel's coordinates with y down, is right on the
    /// rope, where it can be taken.
    func isOnRope(_ p: CGPoint) -> Bool {
        guard revealed, p.x >= 0, p.x <= width else { return false }
        let y = topOffset + RopeBend.restY(at: p.x, width: width) + rope.drop(at: p.x, width: width)
        return abs(p.y - y) <= RopeView.reach
    }

    private func grabRope(at x: CGFloat) {
        bounce?.invalidate()
        bounce = nil
        ropeHeld = true
        // Taken again while it still bounces: it is held where it is now.
        let now = rope.pullDepth != 0 ? RopeBend.drop(at: x, load: rope.pullX, depth: rope.pullDepth, width: width) : 0
        heldFrom = now
        rope.setPull(x: x, depth: now)
        lowerPhotos()
    }
    private var heldFrom: CGFloat = 0

    /// Pulled `dy` points from where it was taken, down positive. The rope
    /// gives easily at first and harder the farther it goes, more so up,
    /// where it is pulled taut against its ends.
    private func pullRope(by dy: CGFloat) {
        guard ropeHeld else { return }
        let raw = heldFrom + dy
        let limit: CGFloat = raw > 0 ? 34 : min(14, max(0, RopeBend.restY(at: rope.pullX, width: width) - 2))
        let depth = limit > 0 ? limit * tanh(raw / limit) : 0
        rope.setPull(x: rope.pullX, depth: depth)
        lowerPhotos()
    }

    /// Let go, the rope springs back past its rest and bounces up and down
    /// a few times, and the photos on it swing as it shakes them.
    private func releaseRope() {
        guard ropeHeld else { return }
        ropeHeld = false
        let from = rope.pullDepth, x = rope.pullX
        guard abs(from) > 0.5 else {
            rope.setPull(x: x, depth: 0)
            lowerPhotos()
            return
        }
        let start = CACurrentMediaTime()
        // About two and a half bounces a second, dying away over a second
        // or two. Driven frame by frame only while it bounces.
        let frequency = 2.4, decay = 2.6
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CACurrentMediaTime() - start
                let envelope = Double(from) * exp(-decay * t)
                if abs(envelope) < 0.3 {
                    self.bounce?.invalidate()
                    self.bounce = nil
                    self.rope.setPull(x: x, depth: 0)
                } else {
                    self.rope.setPull(x: x, depth: CGFloat(envelope * cos(2 * .pi * frequency * t)))
                }
                self.lowerPhotos()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        bounce = timer
        // The jerk sets every photo swinging, the ones near the hand most.
        for item in items where !item.falling && item.id != draggingID && item.id != slidingID {
            let pin = CGFloat(item.position) * width
            let near = Double(RopeBend.drop(at: pin, load: x, depth: 1, width: width))
            let degrees = min(9, abs(Double(from)) * 0.22) * (0.35 + 0.65 * near) * .random(in: 0.7...1.1)
            sway(item.id).nudge((Bool.random() ? 1 : -1) * degrees)
        }
    }

    /// A jolt on the rope near `x`: the photos close by swing a little.
    func jolt(at x: CGFloat, strength: Double) {
        for item in items where !item.falling && item.id != draggingID && item.id != slidingID {
            let d = abs(CGFloat(item.position) * width - x)
            guard d < 260 else { continue }
            let near = Double(1 - d / 260)
            sway(item.id).nudge((Bool.random() ? 1 : -1) * strength * near * .random(in: 0.6...1))
        }
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 15...35)) { [weak self] in
            guard let self else { return }
            // Only while the line is in view: a breeze nobody sees would
            // still keep SwiftUI redrawing the swinging cards.
            if self.breezeOn && self.revealed && !self.items.isEmpty && self.draggingID == nil && self.slidingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let live = items.filter { !$0.falling }
        UserDefaults.standard.set(live.map(\.url.path), forKey: storeKey)
        let positions = Dictionary(live.map { ($0.url.path, $0.position) }, uniquingKeysWith: { $1 })
        UserDefaults.standard.set(positions, forKey: positionsKey)
    }

    private func restore() {
        let paths = (UserDefaults.standard.stringArray(forKey: storeKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
        let positions = UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: Double] ?? [:]
        // The cards' pictures are made side by side on every core, so the
        // line is ready sooner at launch.
        let urls = paths.map { URL(fileURLWithPath: $0) }
        // Each task writes only its own slot.
        nonisolated(unsafe) let thumbs = UnsafeMutableBufferPointer<NSImage?>.allocate(capacity: urls.count)
        thumbs.initialize(repeating: nil)
        defer { _ = thumbs.deinitialize(); thumbs.deallocate() }
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in thumbs[i] = makeThumbnail(urls[i]) }
        for (index, url) in urls.enumerated() {
            // Lines saved before photos could be moved keep their old, even layout.
            let position = positions[url.path]
                ?? Double(Layout.x(index: index, count: paths.count, width: width) / width)
            if let thumb = thumbs[index] { hang(url, thumb: thumb, quietly: true, at: position) }
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

func makeThumbnail(_ url: URL, maxPixels: Int = 480) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
