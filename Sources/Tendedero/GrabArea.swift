import AppKit
import SwiftUI

/// Bridges each photo to AppKit's drag and drop, so it can be dragged into
/// any app as a real file. Each destination means one thing:
///
/// - An app gets a copy, and the photo stays on the line.
/// - A folder or the Desktop keeps the file, and the photo leaves the line.
/// - The Trash discards it.
/// - Nowhere that accepts it: the photo flies back to the line.
///
/// Dragged sideways, the photo slides along the line to any spot instead.
/// Pulling it down off the line turns the slide into a drag out.
///
/// Click copies, double click shows it large, press and hold opens Markup,
/// the corner cross discards. Whatever you click or slide comes to the front.
struct GrabArea: NSViewRepresentable {
    let item: Pegged
    let line: Line

    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabView, context: Context) {
        configure(view)
    }

    private func configure(_ view: GrabView) {
        let id = item.id
        let line = line
        view.url = item.url
        view.dragImage = item.thumb
        view.onClick = {
            line.copy(id)
            line.bringToFront(id)
        }
        view.onDoubleClick = { line.show(id) }
        view.onSlideStart = { line.beginSlide(id) }
        view.onSlide = { dx in line.slide(id, by: dx) }
        view.onSlideEnd = { line.endSlide() }
        view.onDragStart = { line.draggingID = id }
        view.onDragEnd = {
            line.draggingID = nil
            // Moved into a folder: it is saved where you wanted it.
            line.prune()
        }
        view.onTrash = { line.trash(id) }
        view.onDiscard = { line.discard(id) }
        view.onLongPress = { line.markup(id) }
        view.onPressChange = { pressed in line.pressedID = pressed ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(L("Copy", "Copiar")) { line.copy(id) })
            menu.addItem(ClosureMenuItem(L("Show", "Ver")) { line.show(id) })
            menu.addItem(ClosureMenuItem(L("Open", "Abrir")) { line.open(id) })
            menu.addItem(ClosureMenuItem(L("Markup", "Marcación")) { line.markup(id) })
            menu.addItem(ClosureMenuItem(L("Show in Finder", "Mostrar en Finder")) { line.reveal(id) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Bring to Front", "Traer al frente")) { line.bringToFront(id) })
            menu.addItem(ClosureMenuItem(L("Send to Back", "Enviar al fondo")) { line.sendToBack(id) })
            menu.addItem(.separator())
            let inInbox = line.isInInbox(id)
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Save to Desktop", "Guardar en el Escritorio")) { line.saveToDesktop(id) })
            }
            menu.addItem(.separator())
            if inInbox {
                menu.addItem(ClosureMenuItem(L("Discard", "Descartar")) { line.discard(id) })
            } else {
                menu.addItem(ClosureMenuItem(L("Take down", "Descolgar")) { line.discard(id) })
                menu.addItem(ClosureMenuItem(L("Move to Trash", "Mover a la Papelera")) { line.trash(id) })
            }
            return menu
        }
    }
}

final class GrabView: NSView, NSDraggingSource {
    static var isDragging = false

    var url: URL?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onSlideStart: () -> Void = {}
    var onSlide: (CGFloat) -> Void = { _ in }
    var onSlideEnd: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var sliding = false
    private var holdTimer: Timer?
    private var didLongPress = false

    /// How long you hold before Markup opens. Long enough not to fire on a
    /// slow click, short enough to feel deliberate.
    private static let holdDuration: TimeInterval = 0.45

    /// How far below the line you pull a sliding photo before it comes off
    /// the line and is dragged out as a file.
    private static let pullOff: CGFloat = 44

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The discard cross drawn in the top left corner of the card. It is
    /// handled here because this view sits on top of the SwiftUI card.
    static let crossHitSize: CGFloat = 26

    private func isInCross(_ event: NSEvent) -> Bool {
        // Where the click falls on the photo as it hangs at rest: a photo
        // swinging in the pointer's air has its cross a little aside.
        var swaying: NSView? = superview
        while let v = swaying, !(v is SwayView) { swaying = v.superview }
        let atRest = (swaying as? SwayView)?.atRest(windowPoint: event.locationInWindow) ?? event.locationInWindow
        let p = convert(atRest, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        if isInCross(event) {
            downPoint = nil
            onDiscard()
            return
        }
        if event.clickCount == 2 {
            downPoint = nil
            onDoubleClick()
            return
        }
        downPoint = event.locationInWindow
        startedDrag = false
        sliding = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag else { return }
        let p = event.locationInWindow
        let dx = p.x - start.x, dy = p.y - start.y
        if sliding {
            // Window coordinates grow upward, so pulling down makes dy negative.
            if -dy > Self.pullOff {
                sliding = false
                onSlideEnd()
                beginFileDrag(with: event)
            } else {
                onSlide(dx)
            }
            return
        }
        guard hypot(dx, dy) > 4, !didLongPress else { return }
        endPress()
        if abs(dx) > abs(dy) {
            sliding = true
            onSlideStart()
            onSlide(dx)
        } else {
            beginFileDrag(with: event)
        }
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let url else { return }
        startedDrag = true

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        // Released where nothing accepts it: it flies back to the line.
        session.animatesToStartingPositionsOnCancelOrFail = true
        GrabView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if sliding {
            sliding = false
            downPoint = nil
            onSlideEnd()
            return
        }
        if downPoint != nil && !startedDrag && !didLongPress && event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Apps pick copy. Finder picks move, so a folder or the Desktop keeps
        // the file. Delete is what lets the Dock's Trash accept it.
        context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        GrabView.isDragging = false
        startedDrag = false
        downPoint = nil
        log.notice("Drag ended with operation \(operation.rawValue, privacy: .public)")
        // Dropped on the Trash: macOS only tells us, we move the file.
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder finishes a move a moment later. Check again then, so a photo
        // saved into a folder leaves the line.
        if operation.contains(.move) {
            let done = onDragEnd
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done() }
        }
    }

    /// The drag preview keeps the photo's aspect ratio inside the card.
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
