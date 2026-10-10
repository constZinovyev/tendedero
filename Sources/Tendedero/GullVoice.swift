import AVFoundation
import AppKit

/// The gull's voice: recordings of real herring gulls, cut into single
/// calls, a few long calls, alarm calls and calls in flight. Each is played
/// a little faster or slower now and then, so they do not repeat exactly,
/// quietly, and from the side of the screen the bird is on.
@MainActor
final class GullVoice {
    enum Kind: String, CaseIterable {
        /// One "kyow", standing.
        case call
        /// The long call, head thrown up, many notes.
        case long
        /// Frightened off: the sharp "ha-ha-ha".
        case alarm
        /// A call passing overhead.
        case flight
    }

    var isOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "gullSoundsOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "gullSoundsOff") }
    }

    private lazy var clips: [Kind: [URL]] = {
        guard let dir = Bundle.main.url(forResource: "Gull", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var result: [Kind: [URL]] = [:]
        for kind in Kind.allCases {
            result[kind] = files.filter { $0.lastPathComponent.hasPrefix(kind.rawValue + "-") }
        }
        return result
    }()

    private var playing: [AVAudioPlayer] = []
    private var last: [Kind: URL] = [:]

    /// A call of `kind` from a bird at `p` (screen coordinates).
    func play(_ kind: Kind, at p: CGPoint) {
        guard isOn else { return }
        playing.removeAll { !$0.isPlaying }
        // Never more than two at once.
        guard playing.count < 2 else { return }
        let options = (clips[kind] ?? []).filter { $0 != last[kind] }
        guard let url = options.randomElement() ?? clips[kind]?.first,
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        last[kind] = url
        player.enableRate = true
        player.rate = .random(in: 0.94...1.06)
        player.volume = kind == .flight ? 0.22 : 0.32
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main {
            let x = (p.x - screen.frame.midX) / (screen.frame.width / 2)
            player.pan = Float(max(-0.8, min(0.8, x * 0.8)))
        }
        player.play()
        playing.append(player)
    }
}
