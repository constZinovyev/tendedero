import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Experimental: the line while the Mac is locked.
///
/// Apps cannot draw over the lock screen, so the line gets there two ways.
/// The Tendedero screen saver plays the moving desktop picture with the line
/// over it, from a picture of the line this keeps up to date in a shared
/// folder. And behind the password prompt, which only ever shows the desktop
/// picture, the desktop picture becomes a still of the line over a frame of
/// that same picture while the screen is locked.
///
/// A moving (aerial) desktop picture cannot be put back with the public API,
/// so the system's own wallpaper settings file is copied aside before the
/// still goes up, and copied back on unlock.
@MainActor
final class LockScreen {
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "lockScreenOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "lockScreenOff") }
    }

    private let line: Line
    private let panel: LinePanel
    /// Garlands and candles hang on the lock screen too, where they are on the desktop.
    private let decorations: Garlands
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var pendingExport: DispatchWorkItem?
    /// The desktop video the pictures were last drawn over.
    private var exportedVideo: URL?
    /// A frame of the moving desktop picture, read once per video.
    private var frameCache: (url: URL, image: CGImage)?

    /// Shared with the screen saver, which reads `line.png` and `state.json`.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tendedero/LockScreen", isDirectory: true)
    }
    private static var overlayURL: URL { folder.appendingPathComponent("line.png") }
    private static var stillURL: URL { folder.appendingPathComponent("still.png") }
    private static var stateURL: URL { folder.appendingPathComponent("state.json") }
    private static var backupURL: URL { folder.appendingPathComponent("wallpaper-backup.plist") }

    private static var wallpaperStore: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    init(line: Line, panel: LinePanel, decorations: Garlands) {
        self.line = line
        self.panel = panel
        self.decorations = decorations
        decorations.objectWillChange
            .sink { [weak self] _ in self?.scheduleExport() }
            .store(in: &cancellables)
        // A crash or a quit while locked leaves the still up: put the real picture back.
        if !Self.screenIsLocked { restore() }
        export()

        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            },
            // The display going dark usually comes right before the lock.
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreUnlessLocked() }
            },
            // A new desktop picture or a new screen: the pictures are redrawn.
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleExport() }
            },
        ]
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

    // MARK: Keeping the pictures current

    /// Called whenever the line changes. Drawing waits for things to settle.
    func scheduleExport() {
        pendingExport?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingExport = nil
            self?.export()
        }
        pendingExport = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Draws the line over a clear screen for the screen saver, and over a
    /// frame of the desktop picture for the password prompt, so locking has
    /// nothing left to draw.
    private func export() {
        guard Self.isEnabled, !Self.screenIsLocked || original == nil,
              let screen = panel.screen ?? Placement.mainScreen else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)

        let video = Self.aerialVideo()
        exportedVideo = video
        let overlay = drawLine(on: screen)
        if let overlay { write(overlay, to: Self.overlayURL) } else { try? fm.removeItem(at: Self.overlayURL) }

        let state: [String: Any] = [
            "video": video?.path ?? "",
            "overlay": overlay == nil ? "" : "line.png",
            "width": screen.frame.width,
            "height": screen.frame.height,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }

        if let overlay, let still = drawStill(on: screen, video: video, overlay: overlay) {
            write(still, to: Self.stillURL)
        } else {
            try? fm.removeItem(at: Self.stillURL)
        }
    }

    // MARK: Putting the still up and taking it down

    /// Whether the still is up, with the real settings set aside.
    private var original: URL? {
        FileManager.default.fileExists(atPath: Self.backupURL.path) ? Self.backupURL : nil
    }

    func apply() {
        guard Self.isEnabled,
              let screen = panel.screen ?? Placement.mainScreen else { return }
        // The pictures are kept current ahead of time, so locking only has
        // to put one up. Drawing it now would hold the line back by a second.
        if pendingExport.map({ !$0.isCancelled }) == true || Self.aerialVideo() != exportedVideo {
            pendingExport?.cancel()
            export()
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.stillURL.path) else { return }

        // Set the real settings aside once; a second lock keeps the first copy.
        if original == nil {
            do {
                try fm.copyItem(at: Self.wallpaperStore, to: Self.backupURL)
            } catch {
                log.error("Lock screen: cannot copy the wallpaper settings, leaving them alone: \(error.localizedDescription, privacy: .public)")
                return
            }
        }

        // A new name every time: the system keeps showing an old picture
        // when the file name stays the same.
        for old in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("locked-") {
            try? fm.removeItem(at: old)
        }
        let shown = Self.folder.appendingPathComponent("locked-\(UUID().uuidString).png")
        do {
            try fm.copyItem(at: Self.stillURL, to: shown)
            try NSWorkspace.shared.setDesktopImageURL(shown, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            log.notice("Lock screen: the line is up")
        } catch {
            log.error("Lock screen: could not set the desktop picture: \(error.localizedDescription, privacy: .public)")
            restore()
        }
    }

    /// Puts the real wallpaper settings back, moving pictures included, and
    /// has the wallpaper agent read them again.
    func restore() {
        guard let backup = original else { return }
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(Self.wallpaperStore, withItemAt: backup)
        } catch {
            log.error("Lock screen: could not put the wallpaper settings back: \(error.localizedDescription, privacy: .public)")
            return
        }
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        agent.arguments = ["WallpaperAgent"]
        try? agent.run()
        agent.waitUntilExit()
        for old in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("locked-") {
            try? fm.removeItem(at: old)
        }
        log.notice("Lock screen: desktop picture restored")
    }

    // MARK: The desktop picture

    /// The video of the moving desktop picture, if one is chosen and downloaded.
    static func aerialVideo() -> URL? {
        guard let data = try? Data(contentsOf: wallpaperStore),
              let store = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        var ids: [String] = []
        func collect(_ value: Any) {
            if let dict = value as? [String: Any] {
                if dict["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                   let config = dict["Configuration"] as? Data,
                   let parsed = try? PropertyListSerialization.propertyList(from: config, format: nil) as? [String: Any],
                   let id = parsed["assetID"] as? String {
                    ids.append(id)
                }
                // The idle (screen saver) choice is not the desktop picture.
                for (key, child) in dict.sorted(by: { $0.key < $1.key }) where key != "Idle" { collect(child) }
            } else if let list = value as? [Any] {
                list.forEach(collect)
            }
        }
        // The setting for every Space and display wins over the older ones.
        for key in ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"] {
            if let part = store[key] { collect(part) }
        }
        let root = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer")
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for id in ids {
            for folder in folders {
                let file = folder.appendingPathComponent("\(id).mov")
                if FileManager.default.isReadableFile(atPath: file.path) { return file }
            }
        }
        return nil
    }

    /// A frame of the moving picture, or the still desktop picture.
    private func background(for screen: NSScreen, video: URL?) -> CGImage? {
        if let video {
            if let cached = frameCache, cached.url == video { return cached.image }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            if let frame = try? generator.copyCGImage(at: .zero, actualTime: nil) {
                frameCache = (video, frame)
                return frame
            }
        }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              !url.lastPathComponent.hasPrefix("locked-") else { return nil }
        return NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Drawing

    private static func context(_ pixels: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func pixels(of screen: NSScreen) -> CGSize {
        let scale = screen.backingScaleFactor
        return CGSize(width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
    }

    /// How far down the screen the line hangs while locked, as a fraction of
    /// the screen's height: below the big clock of the lock screen. Fixed,
    /// whatever distance from the top the line has on the desktop.
    static let lockedTop: CGFloat = 0.20

    /// The whole screen, clear: the garlands and candles where they hang on
    /// the desktop, and the line as if it were down, across the same stretch
    /// as on the desktop, at the locked height. Nil when there is nothing.
    private func drawLine(on screen: NSScreen) -> CGImage? {
        let items = line.items.filter { !$0.falling }
        let showDecorations = decorations.visible && !decorations.isEmpty && Placement.allows(screen)
        guard !items.isEmpty || showDecorations, let ctx = Self.context(Self.pixels(of: screen)) else { return nil }
        let scale = screen.backingScaleFactor
        if showDecorations { drawDecorations(on: screen, in: ctx) }
        guard !items.isEmpty else { return ctx.makeImage() }
        let width = panel.frame.width
        let height = Layout.panelHeight
        let renderer = ImageRenderer(content: StillLine(items: items, width: width, topOffset: 0))
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = scale
        guard let still = renderer.cgImage else { return nil }
        let top = (screen.frame.height * Self.lockedTop).rounded()
        let origin = CGPoint(x: (panel.frame.minX - screen.frame.minX) * scale,
                             y: (screen.frame.height - top - height) * scale)
        ctx.draw(still, in: CGRect(origin: origin, size: CGSize(width: width * scale, height: height * scale)))
        return ctx.makeImage()
    }

    /// The same layers the desktop shows, standing still: a blinking bulb or
    /// a flickering flame is drawn as it rests.
    private func drawDecorations(on screen: NSScreen, in ctx: CGContext) {
        let scale = screen.backingScaleFactor
        let garlands = GarlandLayers()
        let candles = CandleLayers()
        garlands.render(decorations.items, style: decorations.style, origin: screen.frame.origin, scale: scale)
        candles.render(decorations.candles, style: decorations.candleStyle, origin: screen.frame.origin, scale: scale)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        candles.root.render(in: ctx)
        garlands.root.render(in: ctx)
        ctx.restoreGState()
    }

    /// The desktop picture filling the screen, and the line over it.
    private func drawStill(on screen: NSScreen, video: URL?, overlay: CGImage) -> CGImage? {
        let pixels = Self.pixels(of: screen)
        guard let ctx = Self.context(pixels) else { return nil }
        let canvas = CGRect(origin: .zero, size: pixels)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(canvas)
        if let picture = background(for: screen, video: video) {
            let w = CGFloat(picture.width), h = CGFloat(picture.height)
            let s = max(pixels.width / w, pixels.height / h)
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: CGRect(x: (pixels.width - w * s) / 2, y: (pixels.height - h * s) / 2,
                                         width: w * s, height: h * s))
        } else {
            log.notice("Lock screen: no desktop picture to draw, using black")
        }
        ctx.draw(overlay, in: canvas)
        return ctx.makeImage()
    }

    private func write(_ image: CGImage, to url: URL) {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            log.error("Lock screen: could not write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
