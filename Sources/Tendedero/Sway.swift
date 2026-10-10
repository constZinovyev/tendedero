import AppKit
import QuartzCore
import SwiftUI

/// The swing of one photo on its pin, played by Core Animation.
///
/// SwiftUI would animate a swing by recomputing the whole line on every
/// frame for seconds; with the line always in view and a breeze every so
/// often, that kept the processor busy. Here each swing is worked out once,
/// as a spring curve sampled into keyframes, and handed to Core Animation,
/// which turns the photo's layer on its own. The app does nothing per frame.
@MainActor
final class Sway {
    fileprivate weak var view: SwayView?

    /// The curve playing now, in degrees, clockwise as SwiftUI counts, so
    /// a new swing can start from where the photo is instead of jumping.
    private var samples: [Double] = []
    private var start: CFTimeInterval = 0
    private var holdsLast = false
    private static let step = 1.0 / 30

    /// Where the swing is now, in degrees.
    var angle: Double {
        guard !samples.isEmpty else { return 0 }
        let t = (CACurrentMediaTime() - start) / Self.step
        if t >= Double(samples.count - 1) { return holdsLast ? samples.last! : 0 }
        let i = Int(t), f = t - Double(i)
        return samples[i] + (samples[i + 1] - samples[i]) * f
    }

    /// How fast it swings now, in degrees a second.
    var speed: Double {
        guard samples.count > 1 else { return 0 }
        let t = (CACurrentMediaTime() - start) / Self.step
        guard t >= 0, t < Double(samples.count - 1) else { return 0 }
        let i = Int(t)
        return (samples[i + 1] - samples[i]) / Self.step
    }

    private var pushed: CFTimeInterval = 0

    /// Air from the pointer moving across the photo at `vx` points a
    /// second, `depth` of the way down it. Like drag, with the square of
    /// the speed, for as long as it blows: a slow hand barely stirs it, a
    /// quick sweep swings it a few degrees. It carries on by its own
    /// inertia and dies away.
    func push(byAirAt vx: Double, depth: Double) {
        let now = CACurrentMediaTime()
        guard now - pushed >= 1.0 / 15 else { return }
        let blowing = min(0.1, now - pushed)
        pushed = now
        // Air moving right pushes the bottom right: anticlockwise, negative
        // the way SwiftUI counts.
        let kick = -(vx * abs(vx) / 1000) * 0.004 * depth * blowing * 15
        guard abs(kick) > 0.2 else { return }
        let w = max(-16, min(16, speed + kick))
        play(Self.pendulum(angle: angle, velocity: w))
    }

    /// A photo swinging on its pin from `a` at `w` degrees a second: about
    /// a second and a half to and fro, dying away over a few seconds.
    private static func pendulum(angle a0: Double, velocity w0: Double) -> [Double] {
        let k = 16.0, c = 1.2, sub = 4, dt = step / Double(sub)
        var a = a0, w = w0
        var curve = [a]
        for _ in 0..<Int(7 / step) {
            for _ in 0..<sub {
                w += (-k * a - c * w) * dt
                a += w * dt
            }
            curve.append(a)
            if abs(a) < 0.02 && abs(w) < 0.1 { break }
        }
        curve.append(0)
        return curve
    }

    /// A little push: out to `degrees` and back, settling like a pendulum.
    func nudge(_ degrees: Double) {
        let from = angle
        let out = Self.ease(from: from, to: degrees, duration: 0.3)
        play(out + Self.spring(from: degrees, stiffness: 38, damping: 2.4).dropFirst())
    }

    /// Swings back to rest from `degrees`.
    func spring(from degrees: Double, stiffness: Double, damping: Double) {
        play(Self.spring(from: degrees, stiffness: stiffness, damping: damping))
    }

    /// While the photo is being slid, it leans behind the pin.
    func follow(_ degrees: Double) {
        play(Self.ease(from: angle, to: degrees, duration: 0.18), hold: true)
    }

    /// Let go after a slide: back to rest.
    func settle() {
        spring(from: angle, stiffness: 38, damping: 2.4)
    }

    /// The rope under the pin has gone down by `points`: the photo goes
    /// down with it.
    func lower(_ points: CGFloat) {
        lowered = points
        view?.lower(points)
    }

    /// How far the rope has taken the photo down.
    private(set) var lowered: CGFloat = 0

    /// Where a point over the photo as it is drawn now, swung about `pin`
    /// and taken down by the rope, falls on the photo at rest. Y down.
    func atRest(_ p: CGPoint, pin: CGPoint) -> CGPoint {
        let a = angle * .pi / 180
        let dx = p.x - pin.x, dy = p.y - pin.y
        return CGPoint(x: pin.x + cos(a) * dx + sin(a) * dy,
                       y: pin.y - sin(a) * dx + cos(a) * dy - lowered)
    }

    private func play(_ curve: [Double], hold: Bool = false) {
        samples = curve
        start = CACurrentMediaTime()
        holdsLast = hold
        view?.play(curve, step: Self.step, hold: hold)
    }

    // MARK: Curves

    private static func ease(from a: Double, to b: Double, duration: Double) -> [Double] {
        let n = max(2, Int(duration / step))
        return (0...n).map { i in
            let t = Double(i) / Double(n)
            return a + (b - a) * (1 - (1 - t) * (1 - t))
        }
    }

    /// A damped spring released from `a` at rest, until it is still.
    private static func spring(from a: Double, stiffness k: Double, damping c: Double) -> [Double] {
        guard abs(a) > 0.01 else { return [0] }
        let wd = (k - c * c / 4).squareRoot()
        let decay = c / 2
        let duration = min(6, Foundation.log(abs(a) / 0.03) / decay)
        let n = max(2, Int(duration / step))
        return (0...n).map { i in
            let t = Double(i) * step
            return a * exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
        } + [0]
    }
}

/// Hosts one photo's SwiftUI view in its own layer, so Core Animation can
/// turn it about the pin. It also reports where the card is, which the
/// panel uses to only catch clicks over photos.
struct SwayHost<Content: View>: NSViewRepresentable {
    static var space: String { "sway" }
    let id: UUID
    let sway: Sway
    let line: Line
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> SwayView {
        let view = SwayView(id: id, line: line)
        sway.view = view
        view.setRoot(root)
        return view
    }

    func updateNSView(_ view: SwayView, context: Context) {
        sway.view = view
        view.setRoot(root)
    }

    static func dismantleNSView(_ view: SwayView, coordinator: ()) {
        view.forget()
    }

    /// Pinned to the top, where the line runs: a hosting view would
    /// otherwise centre the photo and leave a gap under the line.
    private var root: AnyView {
        AnyView(content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: Self.space))
    }
}

@MainActor
final class SwayView: NSView {
    private let id: UUID
    private let line: Line
    private var host: NSHostingView<AnyView>?
    /// The card's rect inside this view, y down, as the card reported it.
    private var cardRect: CGRect?

    init(id: UUID, line: Line) {
        self.id = id
        self.line = line
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func setRoot(_ root: AnyView) {
        let wrapped = AnyView(root.onPreferenceChange(HitRectsKey.self) { [weak self] rects in
            MainActor.assumeIsolated { self?.cardMoved(rects) }
        })
        if let host {
            host.rootView = wrapped
        } else {
            let host = NSHostingView(rootView: wrapped)
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }

    // MARK: Where the card is

    /// AppKit finds the view under a click by the frames, which stay put
    /// while Core Animation swings the photo. The point is turned back to
    /// where it falls on the photo at rest, so a click lands on the photo
    /// as it is drawn.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let q = line.sway(id).atRest(CGPoint(x: local.x, y: bounds.height - local.y),
                                     pin: CGPoint(x: bounds.midX, y: 0))
        return super.hitTest(convert(NSPoint(x: q.x, y: bounds.height - q.y), to: superview))
    }

    private func cardMoved(_ rects: [UUID: CGRect]) {
        cardRect = rects[id]
        report()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        report()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        report()
    }

    /// Converts the card's rect to the panel's coordinates, y down from the
    /// top, the way the panel reads them.
    private func report() {
        guard let host, let window, let content = window.contentView else { return }
        guard let r = cardRect else {
            forget()
            return
        }
        let inWindow = host.convert(r, to: nil)
        let rect = CGRect(x: inWindow.minX, y: content.bounds.height - inWindow.maxY,
                          width: inWindow.width, height: inWindow.height)
        line.hitRects[id] = rect
        reported = rect
    }

    /// The last rect this view reported, so it only ever clears its own.
    private var reported: CGRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report()
    }

    /// Clears the card's rect, unless a newer view for the same photo has
    /// already reported its own: when a photo comes to the front SwiftUI may
    /// build its new view before taking the old one down, and wiping the new
    /// rect would let the next click, like the second of a double click, go
    /// through to the desktop.
    func forget() {
        if let reported, line.hitRects[id] == reported { line.hitRects[id] = nil }
        reported = nil
    }

    // MARK: Swinging

    /// Moves the photo down with the rope, apart from its swing.
    func lower(_ points: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = points == 0 ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -points, 0)
        CATransaction.commit()
    }

    /// Turns the view about the middle of its top edge, where the pin is.
    func play(_ degrees: [Double], step: Double, hold: Bool) {
        guard let layer, degrees.count > 1 else {
            layer?.removeAnimation(forKey: "sway")
            return
        }
        let w = bounds.width, h = bounds.height
        // The pivot in the layer's own space, whatever its anchor point is.
        let px = w / 2 - layer.anchorPoint.x * w
        let py = h - layer.anchorPoint.y * h
        let values = degrees.map { d -> NSValue in
            // SwiftUI turns clockwise for positive angles; Core Animation,
            // with y up, the other way.
            var t = CATransform3DMakeTranslation(px, py, 0)
            t = CATransform3DRotate(t, CGFloat(-d * .pi / 180), 0, 0, 1)
            t = CATransform3DTranslate(t, -px, -py, 0)
            return NSValue(caTransform3D: t)
        }
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = values
        a.calculationMode = .linear
        a.duration = step * Double(degrees.count - 1)
        if hold {
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        if #available(macOS 12.0, *) {
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        }
        layer.add(a, forKey: "sway")
    }
}
