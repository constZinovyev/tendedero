import AppKit
import SwiftUI

/// The notebook off the rope, lying wherever it was put down: a small
/// panel of its own that stays on the desktop whether the line is up or
/// tucked away.
@MainActor
final class FreeNotebookPanel: NSPanel {
    /// Room around the cover for its shadow.
    static let margin: CGFloat = 16
    static var size: CGSize {
        CGSize(width: NotebookLook.hangingSize.width + NotebookLook.tabReach + margin * 2,
               height: NotebookLook.hangingSize.height + margin * 2)
    }

    let model = FreeNotebookModel()
    var onTap: (() -> Void)?
    var onDrop: (() -> Void)?
    private var grab: (mouse: NSPoint, origin: NSPoint)?

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: FreeNotebookView(model: model, panel: self))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    func applyLevel() {
        level = Placement.behindWindows
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            : .floating
    }

    /// The cover, in screen coordinates.
    var coverFrame: CGRect {
        CGRect(x: frame.minX + Self.margin, y: frame.minY + Self.margin,
               width: NotebookLook.hangingSize.width, height: NotebookLook.hangingSize.height)
    }

    /// Puts the cover's top centre at `point`, kept on its screen.
    func place(coverTop point: NSPoint) {
        let size = Self.size
        var origin = NSPoint(x: point.x - Self.margin - NotebookLook.hangingSize.width / 2,
                             y: point.y - size.height + Self.margin)
        if let visible = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX - Self.margin), visible.maxX - size.width + Self.margin)
            origin.y = min(max(origin.y, visible.minY - Self.margin), visible.maxY - size.height + Self.margin)
        }
        setFrameOrigin(origin)
    }

    // MARK: Dragging, from the view

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if grab == nil { grab = (mouse, frame.origin) }
        guard let grab else { return }
        if !model.moving, hypot(mouse.x - grab.mouse.x, mouse.y - grab.mouse.y) < 3 { return }
        model.moving = true
        setFrameOrigin(NSPoint(x: grab.origin.x + mouse.x - grab.mouse.x, y: grab.origin.y + mouse.y - grab.mouse.y))
    }

    func dragEnded() {
        grab = nil
        if model.moving {
            model.moving = false
            onDrop?()
        } else {
            onTap?()
        }
    }
}

@MainActor
final class FreeNotebookModel: ObservableObject {
    @Published var tabs: [String] = []
    @Published var moving = false
    @Published var hidden = false
}

/// The closed notebook lying on the desktop, a little lifted while it is
/// carried.
struct FreeNotebookView: View {
    @ObservedObject var model: FreeNotebookModel
    let panel: FreeNotebookPanel
    @State private var hovering = false
    @State private var landed = false

    var body: some View {
        let size = NotebookLook.hangingSize
        let lifted = model.moving || hovering
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                ForEach(Array(model.tabs.enumerated()), id: \.offset) { _, hex in
                    RoundedRectangle(cornerRadius: 2).fill(NotebookLook.color(hex)).frame(width: 14, height: 15)
                }
            }
            .offset(x: size.width - 14 + NotebookLook.tabReach, y: 18)
            NotebookCover()
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(model.moving ? 0.34 : 0.26), radius: model.moving ? 12 : 7, y: model.moving ? 9 : 4)
        }
        .frame(width: size.width + NotebookLook.tabReach, height: size.height, alignment: .topLeading)
        .scaleEffect(model.moving ? 1.05 : (hovering ? 1.02 : 1))
        .rotationEffect(.degrees(model.moving ? -2 : 0))
        .scaleEffect(landed ? 1 : 1.06)
        .opacity(model.hidden ? 0 : 1)
        .frame(width: FreeNotebookPanel.size.width, height: FreeNotebookPanel.size.height)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in panel.dragChanged() }
                .onEnded { _ in panel.dragEnded() }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: lifted)
        .onAppear { withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { landed = true } }
    }
}
