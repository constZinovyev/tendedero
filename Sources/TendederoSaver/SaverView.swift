import AVFoundation
import ScreenSaver
import os

private let log = Logger(subsystem: "app.tendedero.Saver", category: "saver")

/// The Tendedero screen saver: the moving desktop picture with the line
/// hanging over it. The app keeps a picture of the line and the path of the
/// desktop video in a shared folder; this only plays and shows them.
@objc(TendederoSaverView)
final class TendederoSaverView: ScreenSaverView {
    private let videoLayer = AVPlayerLayer()
    private let lineLayer = CALayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoPath = ""
    private var lineStamp: Date?
    private var stopObserver: NSObjectProtocol?

    /// The real home folder: inside the screen saver sandbox the home
    /// directory points into a container.
    private static var folder: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Tendedero/LockScreen", isDirectory: true)
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        for sublayer in [videoLayer, lineLayer] {
            sublayer.frame = bounds
            sublayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(sublayer)
        }
        videoLayer.videoGravity = .resizeAspectFill
        // The line picture is the size of the screen, so it fills the view
        // the same way the video does, the small preview included.
        lineLayer.contentsGravity = .resizeAspectFill
        animationTimeInterval = 2
        // Since Sonoma the saver is not always told to stop; it is told this.
        stopObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screensaver.willstop"), object: nil, queue: .main
        ) { [weak self] _ in self?.player?.pause() }
        reload()
    }

    deinit {
        if let stopObserver { DistributedNotificationCenter.default().removeObserver(stopObserver) }
    }

    override func startAnimation() {
        super.startAnimation()
        reload()
        player?.play()
    }

    override func stopAnimation() {
        super.stopAnimation()
        player?.pause()
    }

    /// Picks up a line that changed while the saver runs.
    override func animateOneFrame() {
        reload()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        lineLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func reload() {
        let folder = Self.folder
        let stateURL = folder.appendingPathComponent("state.json")
        let state: [String: Any]
        do {
            state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any] ?? [:]
        } catch {
            log.error("Cannot read \(stateURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let video = state["video"] as? String ?? ""
        if video != videoPath {
            videoPath = video
            startVideo(video)
        }

        let lineURL = folder.appendingPathComponent("line.png")
        let stamp = (try? lineURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard (state["overlay"] as? String ?? "").isEmpty == false else {
            lineLayer.contents = nil
            lineStamp = nil
            return
        }
        guard stamp != lineStamp else { return }
        if let image = NSImage(contentsOf: lineURL) {
            lineLayer.contents = image
            lineStamp = stamp
        } else {
            log.error("Cannot read \(lineURL.path, privacy: .public)")
        }
    }

    private func startVideo(_ path: String) {
        player?.pause()
        looper = nil
        player = nil
        videoLayer.player = nil
        guard !path.isEmpty else { return }
        guard FileManager.default.isReadableFile(atPath: path) else {
            log.error("Cannot read the desktop video \(path, privacy: .public)")
            return
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: URL(fileURLWithPath: path)))
        videoLayer.player = queue
        player = queue
        if isAnimating { queue.play() }
        log.notice("Playing \(path, privacy: .public)")
    }
}
