import AppKit

/// Where and how the line hangs. Kept in the user defaults.
enum Placement {
    /// Only on the main screen, the one with the Dock and the main menu bar.
    static var mainScreenOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "mainScreenOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "mainScreenOnly") }
    }

    /// Behind the windows, on the desktop, instead of floating over them.
    static var behindWindows: Bool {
        get { UserDefaults.standard.bool(forKey: "behindWindows") }
        set { UserDefaults.standard.set(newValue, forKey: "behindWindows") }
    }

    /// How far below the menu bar the line hangs, in points.
    static var topOffset: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "topOffset")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "topOffset") }
    }

    static let maxTopOffset: CGFloat = 400

    static var mainScreen: NSScreen? { NSScreen.screens.first }

    /// Whether the line may come down on this screen.
    static func allows(_ screen: NSScreen) -> Bool {
        !mainScreenOnly || screen == mainScreen
    }
}

/// A transparent strip along the top of the screen that floats over every
/// app and every Space except full screen ones, never takes focus, and lets clicks pass through
/// everywhere except over the photos.
final class LinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        applyLevel()
        // Every Space except full screen ones: a video or a presentation in full
        // screen should never get a clothesline across the top.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = content
    }

    /// Over every window, or just above the desktop icons and under every window.
    func applyLevel() {
        level = Placement.behindWindows
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The line hangs on the screen you are using, which is the one with the
    /// pointer: that is where you just took the screenshot.
    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The panel runs from the menu bar down, so a line hung lower still
    /// slides out from under the menu bar.
    func placeOnScreen(_ screen: NSScreen? = nil) {
        let chosen = Placement.mainScreenOnly ? Placement.mainScreen : (screen ?? LinePanel.screenUnderPointer())
        guard let visible = chosen?.visibleFrame else { return }
        let height = Layout.panelHeight + Placement.topOffset
        let target = NSRect(x: visible.minX, y: visible.maxY - height,
                            width: visible.width, height: height)
        if frame != target { setFrame(target, display: true) }
    }
}
