import AppKit
import Combine

/// A string of little warm lights hung anywhere on the screen, from one point
/// to another. Purely decorative: it never takes a click unless you are
/// editing it.
struct Garland: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The two ends, in global screen coordinates (AppKit: y grows upward).
    /// A garland may cross from one screen to another.
    var start: CGPoint
    var end: CGPoint
    /// How far the middle hangs below the straight line between the ends.
    var sag: CGFloat = 45
    /// Distance between bulbs along the wire.
    var spacing: CGFloat = 34
    var brightness: Double = 0.85
    var mode: Mode = .on
    /// 1 is the normal pace of blinking and of the wave.
    var speed: Double = 1
    /// Bulbs switched off one by one, by their index from the start.
    var bulbsOff: Set<Int> = []

    enum Mode: String, Codable, CaseIterable {
        /// Every bulb lit.
        case on
        /// Every bulb dark.
        case off
        /// All bulbs go out and light up again together.
        case blink
        /// A wave of light runs along the string.
        case wave

        var title: String {
            switch self {
            case .on: L("On", "Encendida")
            case .off: L("Off", "Apagada")
            case .blink: L("Blink together", "Parpadeo conjunto")
            case .wave: L("Running wave", "Ola de luz")
            }
        }
    }

    static let spacingRange: ClosedRange<CGFloat> = 14...90
    static let speedRange: ClosedRange<Double> = 0.2...3
}

// MARK: Geometry

/// Where the wire runs and where the bulbs sit. Independent of how they are
/// drawn.
struct GarlandGeometry {
    /// Points along the wire, evenly spaced in the curve's parameter.
    let points: [CGPoint]
    /// Distance along the wire to each point.
    let lengths: [CGFloat]

    var length: CGFloat { lengths.last ?? 0 }

    /// The wire hangs as a parabola: a quadratic curve whose control point
    /// sits twice the sag below the middle, so the lowest point of the curve
    /// is exactly `sag` below the line between the ends.
    init(_ g: Garland, samples: Int = 240) {
        let control = Self.control(for: g)
        var pts: [CGPoint] = []
        pts.reserveCapacity(samples + 1)
        for i in 0...samples {
            let s = CGFloat(i) / CGFloat(samples), u = 1 - s
            pts.append(CGPoint(x: u * u * g.start.x + 2 * u * s * control.x + s * s * g.end.x,
                               y: u * u * g.start.y + 2 * u * s * control.y + s * s * g.end.y))
        }
        var lens: [CGFloat] = [0]
        lens.reserveCapacity(pts.count)
        for i in 1..<pts.count {
            lens.append(lens[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        points = pts
        lengths = lens
    }

    static func control(for g: Garland) -> CGPoint {
        CGPoint(x: (g.start.x + g.end.x) / 2, y: (g.start.y + g.end.y) / 2 - 2 * g.sag)
    }

    /// The middle of the curve, where the sag handle sits while editing.
    static func middle(of g: Garland) -> CGPoint {
        CGPoint(x: (g.start.x + g.end.x) / 2, y: (g.start.y + g.end.y) / 2 - g.sag)
    }

    /// The unit normal at a sample, used to twist the strands around the wire.
    func normal(at i: Int) -> CGVector {
        let p = points[max(0, i - 1)], q = points[min(points.count - 1, i + 1)]
        let dx = q.x - p.x, dy = q.y - p.y, l = max(hypot(dx, dy), 0.0001)
        return CGVector(dx: -dy / l, dy: dx / l)
    }

    /// One bulb every `spacing`, starting half a step in so the string looks
    /// even at both ends.
    func bulbPositions(spacing: CGFloat) -> [CGPoint] {
        guard length > 0, spacing > 0 else { return [] }
        var result: [CGPoint] = []
        var j = 0
        var d = spacing / 2
        while d < length {
            while j < lengths.count - 1 && lengths[j] < d { j += 1 }
            result.append(points[j])
            d += spacing
        }
        return result
    }

    /// The shortest distance from a point to the wire.
    func distance(to p: CGPoint) -> CGFloat {
        points.reduce(.greatestFiniteMagnitude) { min($0, hypot($1.x - p.x, $1.y - p.y)) }
    }
}

// MARK: Light

/// How bright a bulb is at a moment, from 0 (dark) to 1 (fully lit). The
/// same curves drive the Core Animation keyframes, so what is computed here
/// is what you see.
enum GarlandLight {
    /// One blink cycle at speed 1: lit, a quick fade out, dark, a quick fade in.
    static let blinkPeriod: Double = 2
    static let blinkTimes: [Double] = [0, 0.45, 0.55, 0.9, 1]
    static let blinkValues: [Double] = [1, 1, 0, 0, 1]

    /// The wave travels this many radians per second at speed 1, and each
    /// bulb lags its neighbour by `waveLag` radians.
    static let waveRate: Double = 2.2
    static let waveLag: Double = 0.55

    static func wave(phase: Double) -> Double {
        0.15 + 0.85 * pow(0.5 + 0.5 * sin(phase), 2)
    }

    static func level(_ g: Garland, bulb i: Int, at t: Double) -> Double {
        if g.bulbsOff.contains(i) { return 0 }
        switch g.mode {
        case .on: return 1
        case .off: return 0
        case .blink:
            let c = (t * g.speed / blinkPeriod).truncatingRemainder(dividingBy: 1)
            for k in 1..<blinkTimes.count where c <= blinkTimes[k] {
                let f = (c - blinkTimes[k - 1]) / (blinkTimes[k] - blinkTimes[k - 1])
                return blinkValues[k - 1] + (blinkValues[k] - blinkValues[k - 1]) * f
            }
            return 1
        case .wave:
            return wave(phase: t * g.speed * waveRate - Double(i) * waveLag)
        }
    }
}

// MARK: Store

/// Every garland, kept in the user defaults.
@MainActor
final class Garlands: ObservableObject {
    @Published private(set) var items: [Garland] = []
    @Published var editing = false
    /// How every garland looks. Saved as soon as it changes.
    @Published var style = GarlandStyle.defaults {
        didSet { saveStyle() }
    }

    var visible: Bool {
        get { !UserDefaults.standard.bool(forKey: "garlandsHidden") }
        set {
            UserDefaults.standard.set(!newValue, forKey: "garlandsHidden")
            objectWillChange.send()
        }
    }

    /// On the desktop, under every window, or floating over them.
    var behindWindows: Bool {
        get { UserDefaults.standard.object(forKey: "garlandsBehindWindows") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "garlandsBehindWindows")
            objectWillChange.send()
        }
    }

    private let storeKey = "garlands"
    private let styleKey = "garlandStyle"

    init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let saved = try? JSONDecoder().decode([Garland].self, from: data) {
            items = saved
        }
        if let data = UserDefaults.standard.data(forKey: styleKey),
           let saved = try? JSONDecoder().decode(GarlandStyle.self, from: data) {
            style = saved
        }
    }

    private func saveStyle() {
        if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: styleKey)
        }
    }

    /// A new garland across the upper part of the screen you are on.
    @discardableResult
    func add(on screen: NSScreen?) -> UUID? {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return nil }
        let y = frame.maxY - frame.height * 0.22
        let g = Garland(start: CGPoint(x: frame.minX + frame.width * 0.15, y: y),
                        end: CGPoint(x: frame.minX + frame.width * 0.85, y: y))
        items.append(g)
        save()
        return g.id
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func update(_ id: UUID, save shouldSave: Bool = true, _ change: (inout Garland) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        items[i].spacing = min(max(items[i].spacing, Garland.spacingRange.lowerBound), Garland.spacingRange.upperBound)
        items[i].speed = min(max(items[i].speed, Garland.speedRange.lowerBound), Garland.speedRange.upperBound)
        items[i].brightness = min(max(items[i].brightness, 0), 1)
        items[i].sag = max(0, items[i].sag)
        if shouldSave { save() }
    }

    /// Switches one bulb off, or back on.
    func toggleBulb(_ index: Int, of id: UUID) {
        update(id) { g in
            if g.bulbsOff.contains(index) { g.bulbsOff.remove(index) } else { g.bulbsOff.insert(index) }
        }
    }

    /// Every garland at once: all on, or all off.
    func setAll(_ mode: Garland.Mode) {
        for g in items { update(g.id, save: false) { $0.mode = mode; $0.bulbsOff = [] } }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
