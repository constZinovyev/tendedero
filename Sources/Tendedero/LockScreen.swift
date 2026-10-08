import AppKit
import SwiftUI

/// Experimental: the line on the lock screen. Apps cannot draw over the lock
/// screen, but it shows the desktop picture. So when the screen locks, the
/// desktop picture of the line's screen becomes a still of the line as it
/// hangs right now, over that same picture, and the real one comes back on
/// unlock. Nothing on it can be touched.
@MainActor
final class LockScreen {
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "lockScreenOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "lockScreenOff") }
    }

    private let line: Line
    private let panel: LinePanel
    private var observers: [NSObjectProtocol] = []

    /// The desktop picture to put back. Kept in the user defaults too, so a
    /// crash while locked still gives it back on the next launch.
    private struct Original: Codable {
        var display: UInt32
        var url: URL
        var scaling: UInt?
        var clipping: Bool?
        var fill: Data?
    }

    private static let originalKey = "lockScreenOriginal"
    private var original: Original? {
        get { UserDefaults.standard.data(forKey: Self.originalKey).flatMap { try? JSONDecoder().decode(Original.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.originalKey) }
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tendedero/LockScreen", isDirectory: true)
    }

    init(line: Line, panel: LinePanel) {
        self.line = line
        self.panel = panel
        restore()

        // The lock itself, and the moments that usually come right before it,
        // so the picture is already in place when the lock screen appears.
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        })

        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restore() }
        })
        // A screen saver or a dark display that ends without a lock.
        for name in ["com.apple.screensaver.didstop"] {
            observers.append(distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreUnlessLocked() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreUnlessLocked() }
        })
    }

    private static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func restoreUnlessLocked() {
        // The lock notification can come a moment after the wake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if !Self.screenIsLocked { self?.restore() }
        }
    }

    // MARK: Putting the still up and taking it down

    func apply() {
        guard Self.isEnabled, line.liveCount > 0,
              let screen = panel.screen ?? Placement.mainScreen,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        else { return }
        let workspace = NSWorkspace.shared

        // Already up: the still is redrawn over the saved picture, not over itself.
        let base: Original
        if let saved = original {
            base = saved
        } else {
            guard let url = workspace.desktopImageURL(for: screen) else { return }
            let options = workspace.desktopImageOptions(for: screen) ?? [:]
            base = Original(
                display: display, url: url,
                scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
                clipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fill: (options[.fillColor] as? NSColor).flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                })
        }

        guard let still = render(on: screen, over: base) else { return }
        do {
            try workspace.setDesktopImageURL(still, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            original = base
            log.notice("Lock screen: the line is up on display \(display)")
        } catch {
            log.error("Lock screen: could not set the desktop picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    func restore() {
        guard let saved = original else { return }
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 == saved.display
        } ?? Placement.mainScreen
        if let screen {
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let s = saved.scaling { options[.imageScaling] = s }
            if let c = saved.clipping { options[.allowClipping] = c }
            if let data = saved.fill,
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                options[.fillColor] = color
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(saved.url, for: screen, options: options)
                log.notice("Lock screen: desktop picture restored")
            } catch {
                log.error("Lock screen: could not restore the desktop picture: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        original = nil
        try? FileManager.default.removeItem(at: Self.folder)
    }

    // MARK: Drawing the still

    /// The whole screen: the desktop picture laid out the way the system lays
    /// it out, and the line where it hangs on that screen.
    private func render(on screen: NSScreen, over base: Original) -> URL? {
        let scale = screen.backingScaleFactor
        let size = screen.frame.size
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let canvas = CGRect(origin: .zero, size: pixels)

        let fill = base.fill.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0) }
        ctx.setFillColor((fill ?? NSColor(white: 0.12, alpha: 1)).cgColor)
        ctx.fill(canvas)
        if let picture = NSImage(contentsOf: base.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let w = CGFloat(picture.width), h = CGFloat(picture.height)
            // Fill the screen unless the picture is set to fit inside it.
            let fits = base.clipping == false
            let s = fits ? min(pixels.width / w, pixels.height / h) : max(pixels.width / w, pixels.height / h)
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: CGRect(x: (pixels.width - w * s) / 2, y: (pixels.height - h * s) / 2,
                                         width: w * s, height: h * s))
        } else {
            log.notice("Lock screen: cannot read the desktop picture \(base.url.path, privacy: .public), using a plain background")
        }

        // The line as if it were down, wherever the panel is right now.
        let width = panel.frame.width
        let height = Layout.panelHeight + Placement.topOffset
        let renderer = ImageRenderer(content: StillLine(items: line.items.filter { !$0.falling },
                                                       width: width, topOffset: Placement.topOffset))
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = scale
        guard let still = renderer.cgImage else { return nil }
        let origin = CGPoint(x: (panel.frame.minX - screen.frame.minX) * scale,
                             y: (panel.frame.maxY - height - screen.frame.minY) * scale)
        ctx.draw(still, in: CGRect(origin: origin, size: CGSize(width: width * scale, height: height * scale)))

        guard let image = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // A new name every time: the system keeps showing an old picture
        // when the file name stays the same.
        let folder = Self.folder
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("line-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            log.error("Lock screen: could not write the still: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// The line as LineView draws it, standing still: no hover, no swing, and a
/// frosted card instead of the live glass, which cannot be drawn offscreen.
private struct StillLine: View {
    let items: [Pegged]
    let width: CGFloat
    let topOffset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rope(width: width)
            ForEach(items) { item in
                let x = CGFloat(item.position) * width
                let ropeY = Layout.ropeY(x: x, width: width)
                StillCard(item: item)
                    .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                    .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
            }
        }
        .frame(width: width, height: Layout.panelHeight)
        .offset(y: topOffset)
        .frame(width: width, height: Layout.panelHeight + topOffset, alignment: .top)
    }
}

private struct StillCard: View {
    let item: Pegged

    var body: some View {
        let photo = PeggedView.photoSize(for: item.thumb.size)
        let frame = RoundedRectangle(cornerRadius: Frame.radius, style: .continuous)
        VStack(spacing: -12) {
            Clothespin()
                .zIndex(1)
            Image(nsImage: item.thumb)
                .resizable()
                .interpolation(.high)
                .frame(width: photo.width, height: photo.height)
                .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .padding(Frame.inset)
                .background(Color.white.opacity(0.38), in: frame)
                .overlay(
                    frame.stroke(
                        LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
                )
                .overlay(frame.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        }
        .rotationEffect(.degrees(item.tilt), anchor: .top)
    }
}
