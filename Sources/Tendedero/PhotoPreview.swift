import AppKit
import Combine
import SwiftUI

/// A large look at one photo. The card on the line grows into it: it opens
/// below the card, lined up with it, in the same glass frame, only bigger.
/// It is only for looking: no editing, no other app. Drag it to move it, drag
/// a corner to resize it. A click on it or elsewhere, the cross, Escape or
/// Space sends it back to the line.
@MainActor
final class PhotoPreview {
    static let shared = PhotoPreview()

    /// The share of the screen the photo may fill, in each direction.
    static var screenFraction: CGFloat = 0.55
    /// Small screenshots are enlarged, but not so much that they blur.
    static let maxScale: CGFloat = 2
    /// How far below the card's top the preview opens, in points.
    static var drop: CGFloat = 90

    private static let open = Animation.spring(response: 0.42, dampingFraction: 0.84)
    private static let shut = Animation.spring(response: 0.34, dampingFraction: 0.95)

    private var session: Session?
    /// One window for every preview, made once: a new window over the whole
    /// screen each time held up the start of the opening.
    private var panel: PreviewPanel?

    /// - Parameters:
    ///   - thumb: the card's own picture. The preview starts growing with it
    ///     at once; the full photo is read in the background and takes its
    ///     place as soon as it is ready, a moment later.
    ///   - card: the hanging card's frame in screen coordinates while it is in
    ///     view. Asked again on closing, so the preview goes back to where the
    ///     card hangs then.
    ///   - tilt: the card's tilt in degrees, so the preview leaves it at the same angle.
    func show(_ url: URL, thumb: NSImage, from card: @escaping () -> CGRect?, tilt: Double, on screen: NSScreen?) {
        session?.close(animation: nil)
        session = nil
        guard let screen = screen ?? NSScreen.main,
              let size = Self.pointSize(of: url) ?? Optional(thumb.size),
              size.width > 0, size.height > 0 else { return }

        let start = card().flatMap { $0.intersects(screen.frame) ? $0 : nil }
        let target = Self.target(for: size, near: start, on: screen)
        let panel = self.panel ?? PreviewPanel(frame: screen.frame)
        self.panel = panel
        let session = Session(image: thumb, panel: panel, screen: screen, card: card, start: start, target: target, tilt: tilt)
        session.onDismiss = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.close()
        }
        self.session = session
        session.present(with: Self.open)

        DispatchQueue.global(qos: .userInteractive).async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let full = CGImageSourceCreateImageAtIndex(
                      source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return }
            let image = NSImage(cgImage: full, size: size)
            DispatchQueue.main.async { [weak session] in session?.showFull(image) }
        }
    }

    /// Made ahead of time, so even the first preview opens without a pause.
    func prepare() {
        if panel == nil, let screen = NSScreen.main { panel = PreviewPanel(frame: screen.frame) }
    }

    /// The photo's size in points, from the file's header, the way NSImage
    /// would give it: a screenshot taken on a Retina screen is half its pixels.
    private static func pointSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let scale = dpi > 0 ? 72 / dpi : 1
        return CGSize(width: w * scale, height: h * scale)
    }

    /// Sends the photo back to where it came from.
    func close() {
        session?.close(animation: Self.shut)
        session = nil
    }

    /// The frame the preview opens in: the photo fitted in a share of the
    /// screen, below the card and lined up with it the way the card sits on
    /// the screen. A card on the right keeps its right edge, so the preview
    /// grows to the left; one in the middle grows evenly; one on the left
    /// grows to the right. Always kept inside the screen.
    private static func target(for size: CGSize, near card: CGRect?, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let box = CGSize(width: visible.width * screenFraction, height: visible.height * screenFraction)
        let photoScale = min(box.width / size.width, box.height / size.height, maxScale)
        let photo = CGSize(width: size.width * photoScale, height: size.height * photoScale)
        let inset = PreviewCard.inset(forWidth: photo.width)
        let w = (photo.width + inset * 2).rounded(), h = (photo.height + inset * 2).rounded()

        var x = visible.midX - w / 2, y = visible.midY - h / 2
        if let card {
            let a = min(max((card.midX - visible.minX) / visible.width, 0), 1)
            x = card.minX + a * card.width - a * w
            y = card.maxY - drop - h
        }
        let margin: CGFloat = 24
        x = min(max(x, visible.minX + margin), visible.maxX - margin - w)
        y = min(max(y, visible.minY + margin), visible.maxY - margin - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }
}

/// One preview on screen: a transparent window over the whole screen, so
/// the card can travel from the line and be moved anywhere without being
/// cut off. It lets clicks through everywhere except over the photo.
@MainActor
private final class Session {
    var onDismiss: () -> Void = {}

    private let panel: PreviewPanel
    private let model: PreviewModel
    private let screen: NSScreen
    private let card: () -> CGRect?
    private let target: CGRect
    private var monitors: [Any] = []
    private var timer: Timer?
    private var hoveredCorner: PreviewStage.Corner?

    init(image: NSImage, panel: PreviewPanel, screen: NSScreen, card: @escaping () -> CGRect?,
         start: CGRect?, target: CGRect, tilt: Double) {
        self.screen = screen
        self.card = card
        self.target = target
        self.panel = panel
        model = PreviewModel(image: image)
        model.maxSize = screen.visibleFrame.size
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        if let host = panel.contentView as? NSHostingView<PreviewStage> {
            host.rootView = PreviewStage(model: model)
        } else {
            panel.contentView = NSHostingView(rootView: PreviewStage(model: model))
        }
        panel.onDismiss = { [weak self] in self?.onDismiss() }
        model.onClose = { [weak self] in self?.onDismiss() }

        if let start {
            model.rect = local(start)
            model.tilt = tilt
        } else {
            // Nothing to grow from: it appears in place, slightly small.
            let t = local(target)
            model.rect = t.insetBy(dx: t.width * 0.04, dy: t.height * 0.04)
            model.opacity = 0
        }
    }

    /// Screen coordinates to the window's, which SwiftUI measures from the top.
    private func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// And back: where the photo is on screen now.
    private var current: CGRect {
        let r = model.rect
        return CGRect(x: r.minX + screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// The full photo, read in the background, in place of the card's picture.
    func showFull(_ image: NSImage) {
        guard timer != nil else { return }
        model.image = image
    }

    func present(with animation: Animation) {
        // The window may still be fading out after the last preview.
        panel.owner = ObjectIdentifier(self)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            self.panel.animator().alphaValue = 1
        }
        panel.makeKeyAndOrderFront(nil)
        withAnimation(animation) {
            model.rect = local(target)
            model.tilt = 0
            model.opacity = 1
        }

        // A click anywhere but on the photo sends it back. Those clicks still
        // go through, so clicking another card copies it as usual.
        let dismiss: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: dismiss) {
            monitors.append(global)
        }
        let panel = panel
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            if e.window !== panel { dismiss(e) }
            return e
        }) {
            monitors.append(local)
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The window only takes the mouse over the photo and its corners, and
    /// the cross shows while the pointer is there. Over a corner the pointer
    /// turns into resize arrows. While you move or resize it, it keeps the
    /// mouse whatever the pointer does.
    ///
    /// The cursor is set here rather than on hover: the window belongs to an
    /// app in the background, and macOS resets the cursor on every move.
    private func trackMouse() {
        if model.interacting {
            model.activeCorner?.cursor.set()
            // So the arrows give way to the normal pointer if the drag ends off the corner.
            hoveredCorner = model.activeCorner
            return
        }
        let mouse = NSEvent.mouseLocation
        let rect = current
        let half = PreviewStage.handle / 2
        let over = NSMouseInRect(mouse, rect.insetBy(dx: -half, dy: -half), false)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if model.hovering != over { model.hovering = over }

        let corner = over ? PreviewStage.Corner.allCases.first { c in
            // SwiftUI's y grows downward; the screen's grows upward.
            let p = CGPoint(x: c.sx > 0 ? rect.maxX : rect.minX, y: c.sy > 0 ? rect.minY : rect.maxY)
            return abs(mouse.x - p.x) <= half && abs(mouse.y - p.y) <= half
        } : nil
        if let corner {
            corner.cursor.set()
        } else if hoveredCorner != nil {
            NSCursor.arrow.set()
        }
        hoveredCorner = corner
    }

    /// Flies back into the card, or fades where it is when the card is not
    /// in view. Without an animation it is gone at once.
    func close(animation: Animation?) {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.ignoresMouseEvents = true
        model.hovering = false
        if hoveredCorner != nil || model.activeCorner != nil { NSCursor.arrow.set() }
        guard let animation else {
            panel.orderOut(nil)
            return
        }
        let me = ObjectIdentifier(self)
        let back = card().flatMap { $0.intersects(screen.frame) ? $0 : nil }
        withAnimation(animation) {
            if let back {
                model.rect = local(back)
            } else {
                let r = model.rect
                model.rect = r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04)
                model.opacity = 0
            }
        }
        let panel = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            // The real card on the line takes over, unless a new preview
            // has taken the window in the meantime.
            guard panel.owner == me else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    if panel.owner == me { panel.orderOut(nil) }
                }
            })
        }
    }
}

@MainActor
private final class PreviewModel: ObservableObject {
    @Published var image: NSImage
    @Published var rect: CGRect = .zero
    @Published var tilt: Double = 0
    @Published var opacity: Double = 1
    @Published var hovering = false
    /// Being moved or resized.
    var interacting = false
    /// The corner being dragged, so its arrows stay while resizing.
    var activeCorner: PreviewStage.Corner?
    var maxSize: CGSize = .zero
    var onClose: () -> Void = {}

    init(image: NSImage) { self.image = image }
}

/// Takes keys without bringing Tendedero to the front, so Escape works and
/// the app you were in stays active.
private final class PreviewPanel: NSPanel {
    var onDismiss: () -> Void = {}
    /// The preview using the window now.
    var owner: ObjectIdentifier?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onDismiss() }

    override func keyDown(with event: NSEvent) {
        // Space, as in Quick Look.
        if event.keyCode == 49 { onDismiss() } else { super.keyDown(with: event) }
    }
}

private struct PreviewStage: View {
    @ObservedObject var model: PreviewModel
    @State private var startRect: CGRect?

    /// The side of the square around each corner that resizes the photo,
    /// half inside the frame and half outside: easy to find without
    /// reaching for the very edge, small enough to leave the photo for moving.
    static let handle: CGFloat = 30
    static let minWidth: CGFloat = 180

    var body: some View {
        let r = model.rect
        ZStack(alignment: .topLeading) {
            PreviewCard(image: model.image, width: r.width, hovering: model.hovering, onClose: model.onClose)
                .frame(width: r.width, height: r.height)
                .rotationEffect(.degrees(model.tilt), anchor: .top)
                // Gestures go before .position, which fills the whole screen:
                // after it they would catch drags anywhere. A click without
                // moving closes the photo, like the cross; a drag moves it.
                .gesture(move)
                .onTapGesture { model.onClose() }
                .position(x: r.midX, y: r.midY)
                .opacity(model.opacity)

            ForEach(Corner.allCases, id: \.self) { corner in
                Color.clear
                    .frame(width: Self.handle, height: Self.handle)
                    .contentShape(Rectangle())
                    .gesture(resize(corner))
                    .position(x: corner.sx > 0 ? r.maxX : r.minX, y: corner.sy > 0 ? r.maxY : r.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The window covers the menu bar too; without this SwiftUI would push
        // everything below it and the card would start off its real spot.
        .ignoresSafeArea()
    }

    private func begin() -> CGRect {
        if let startRect { return startRect }
        startRect = model.rect
        model.interacting = true
        return model.rect
    }

    private func end() {
        startRect = nil
        model.interacting = false
        model.activeCorner = nil
    }

    private var move: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { v in
                let s = begin()
                model.rect.origin = CGPoint(x: s.minX + v.translation.width, y: s.minY + v.translation.height)
            }
            .onEnded { _ in end() }
    }

    /// Resizing keeps the photo's proportions and the opposite corner in place.
    private func resize(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let s = begin()
                model.activeCorner = corner
                let byX = s.width + corner.sx * v.translation.width
                let byY = (s.height + corner.sy * v.translation.height) * s.width / s.height
                let limit = min(model.maxSize.width, model.maxSize.height * s.width / s.height)
                let w = min(max(abs(byX - s.width) > abs(byY - s.width) ? byX : byY, Self.minWidth), limit)
                let h = w * s.height / s.width
                model.rect = CGRect(x: corner.sx > 0 ? s.minX : s.maxX - w,
                                    y: corner.sy > 0 ? s.minY : s.maxY - h,
                                    width: w, height: h)
            }
            .onEnded { _ in end() }
    }

    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var sx: CGFloat { self == .topRight || self == .bottomRight ? 1 : -1 }
        var sy: CGFloat { self == .bottomLeft || self == .bottomRight ? 1 : -1 }

        /// The diagonal resize arrows. macOS 15 has them as public API;
        /// macOS 14 only has the private ones, and a crosshair if even those
        /// are missing.
        var cursor: NSCursor {
            if #available(macOS 15, *) {
                let position: NSCursor.FrameResizePosition = switch self {
                case .topLeft: .topLeft
                case .topRight: .topRight
                case .bottomLeft: .bottomLeft
                case .bottomRight: .bottomRight
                }
                return NSCursor.frameResize(position: position, directions: .all)
            }
            let name = sx == sy ? "_windowResizeNorthWestSouthEastCursor" : "_windowResizeNorthEastSouthWestCursor"
            let selector = NSSelectorFromString(name)
            if NSCursor.responds(to: selector),
               let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
                return cursor
            }
            return .crosshair
        }
    }
}

/// The hanging card, drawn larger: the same glass frame and concentric
/// corners. The frame grows with the card, but less than in proportion, so
/// a big photo does not end up looking like a pill.
struct PreviewCard: View {
    let image: NSImage
    let width: CGFloat
    let hovering: Bool
    var onClose: () -> Void = {}

    static func inset(forWidth width: CGFloat) -> CGFloat {
        min(12, Frame.inset * max(1, width / Layout.cardWidth).squareRoot())
    }

    static func radius(forWidth width: CGFloat) -> CGFloat {
        min(30, Frame.radius * max(1, width / Layout.cardWidth).squareRoot())
    }

    var body: some View {
        let inset = Self.inset(forWidth: width)
        let radius = Self.radius(forWidth: width)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .clipShape(RoundedRectangle(cornerRadius: radius - inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius - inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .padding(inset)
            .glassFrame(cornerRadius: radius)
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassFrame(circle: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(inset + 6)
                    .opacity(hovering ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .animation(.easeOut(duration: 0.18), value: hovering)
            }
    }
}
