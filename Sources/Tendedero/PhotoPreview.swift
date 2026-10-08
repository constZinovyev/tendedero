import AppKit
import SwiftUI

/// A large look at one photo, floating in the middle of the screen. It is
/// only for looking: no editing, no other app. A click anywhere, Escape or
/// Space puts it away.
@MainActor
final class PhotoPreview {
    static let shared = PhotoPreview()

    /// The share of the screen the photo may fill, in each direction.
    static var screenFraction: CGFloat = 0.7
    /// Small screenshots are enlarged, but not so much that they blur.
    static let maxScale: CGFloat = 2

    private var panel: PreviewPanel?
    private var monitors: [Any] = []

    func show(_ url: URL, on screen: NSScreen?) {
        close(animated: false)
        guard let image = NSImage(contentsOf: url),
              let visible = (screen ?? NSScreen.main)?.visibleFrame,
              image.size.width > 0, image.size.height > 0 else { return }

        let box = CGSize(width: visible.width * Self.screenFraction, height: visible.height * Self.screenFraction)
        let scale = min(box.width / image.size.width, box.height / image.size.height, Self.maxScale)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)

        let panel = PreviewPanel(frame: frame)
        panel.contentView = NSHostingView(rootView: PreviewView(image: image))
        panel.onDismiss = { [weak self] in self?.close() }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // Any click puts it away, in another app or on the line. The click
        // still goes through, so clicking another photo copies it as usual.
        let dismiss: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: dismiss) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            dismiss(e)
            return e
        }) {
            monitors.append(local)
        }
    }

    func close(animated: Bool = true) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}

/// Takes keys without bringing Tendedero to the front, so Escape works and
/// the app you were in stays active.
final class PreviewPanel: NSPanel {
    var onDismiss: () -> Void = {}

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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

private struct PreviewView: View {
    let image: NSImage
    @State private var shown = false

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .scaleEffect(shown ? 1 : 0.96)
            .onAppear {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { shown = true }
            }
    }
}
