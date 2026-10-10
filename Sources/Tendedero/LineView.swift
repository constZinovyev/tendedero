import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// The even layout used before photos could be moved; still used to
    /// place photos saved by older versions.
    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                RopeHost(bend: line.rope)
                    .frame(width: width, height: Layout.panelHeight)

                if line.items.isEmpty {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                // The views keep one order whatever the stacking, which is
                // left to zIndex: reordering them made SwiftUI build a photo's
                // view again from scratch when it came to the front, a pause
                // and a replayed arrival right as you clicked.
                let stack = Dictionary(uniqueKeysWithValues: line.items.enumerated().map { ($1.id, Double($0)) })
                ForEach(line.items.sorted { $0.id.uuidString < $1.id.uuidString }) { item in
                    let x = CGFloat(item.position) * width
                    let ropeY = Layout.ropeY(x: x, width: width)
                    SwayHost(id: item.id, sway: line.sway(item.id), line: line) {
                        PeggedView(item: item, line: line)
                    }
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                        .zIndex(line.slidingID == item.id ? Double(line.items.count) : stack[item.id] ?? 0)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? line.topOffset : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        // Each photo reports where its card is itself, from its own host
        // (see SwayView), since it lives in a view of its own.
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here", "Haz una captura y se quedará colgada aquí"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

/// The live line's rope: the same as Rope, drawn by Core Animation so a
/// bird sitting on it can pull it down.
@MainActor
final class RopeBend {
    fileprivate weak var view: RopeView?
    fileprivate(set) var x: CGFloat = 0
    fileprivate(set) var depth: CGFloat = 0

    func set(x: CGFloat, depth: CGFloat) {
        guard x != self.x || depth != self.depth else { return }
        self.x = x
        self.depth = depth
        view?.redraw()
    }

    /// Where the rope runs beyond each edge of the screen.
    static let overhang: CGFloat = 20

    /// How far below its rest the rope is at `px` with `depth` at `load`:
    /// a taut rope under a point weight runs straight from each end to it.
    static func drop(at px: CGFloat, load: CGFloat, depth: CGFloat, width: CGFloat) -> CGFloat {
        let a = -overhang, b = width + overhang
        guard depth != 0, load > a, load < b, px > a, px < b else { return 0 }
        return depth * (px < load ? (px - a) / (load - a) : (b - px) / (b - load))
    }

    /// The rope at rest at `px`, from the top of the panel, y down.
    static func restY(at px: CGFloat, width: CGFloat) -> CGFloat {
        let t = (px + overhang) / (width + overhang * 2)
        return Layout.ropeTop + 4 * Layout.sag(width: width) * t * (1 - t)
    }
}

struct RopeHost: NSViewRepresentable {
    let bend: RopeBend

    func makeNSView(context: Context) -> RopeView {
        let view = RopeView()
        bend.view = view
        view.bend = bend
        return view
    }

    func updateNSView(_ view: RopeView, context: Context) {
        bend.view = view
        view.bend = bend
        view.redraw()
    }
}

@MainActor
final class RopeView: NSView {
    weak var bend: RopeBend?
    private let ropeLayers: CALayer = CALayer()
    private let shade = CAShapeLayer(), core = CAShapeLayer(), shine = CAShapeLayer()
    private let fade = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // Like Rope: a soft shadow, a mid gray core and a faint highlight.
        for (l, color, w) in [(shade, NSColor.black.withAlphaComponent(0.16), 2.2),
                              (core, NSColor(white: 0.55, alpha: 1), 1.2),
                              (shine, NSColor.white.withAlphaComponent(0.45), 0.4)] as [(CAShapeLayer, NSColor, CGFloat)] {
            l.fillColor = nil
            l.strokeColor = color.cgColor
            l.lineWidth = w
            l.lineJoin = .round
            ropeLayers.addSublayer(l)
        }
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.25
        shade.shadowRadius = 1
        shade.shadowOffset = .zero
        // It fades out at both ends, as if it came from beyond the screen.
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.08, 0.92, 1]
        ropeLayers.mask = fade
        layer?.addSublayer(ropeLayers)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [shade, core, shine] { l.contentsScale = scale }
    }

    /// Draws the rope as it hangs now. This view's layer has y up.
    func redraw() {
        let w = bounds.width, h = bounds.height
        guard w > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ropeLayers.frame = bounds
        fade.frame = bounds
        let load = bend?.x ?? 0, depth = bend?.depth ?? 0
        func y(_ px: CGFloat) -> CGFloat {
            h - RopeBend.restY(at: px, width: w) - RopeBend.drop(at: px, load: load, depth: depth, width: w)
        }
        let path = CGMutablePath()
        let a = -RopeBend.overhang, b = w + RopeBend.overhang
        if depth == 0 {
            path.move(to: CGPoint(x: a, y: y(a)))
            path.addQuadCurve(to: CGPoint(x: b, y: y(b)),
                              control: CGPoint(x: w / 2, y: h - Layout.ropeTop - 2 * Layout.sag(width: w)))
        } else {
            let n = 160
            var xs = (0...n).map { a + (b - a) * CGFloat($0) / CGFloat(n) }
            xs.append(load)
            xs.sort()
            for (i, px) in xs.enumerated() {
                let p = CGPoint(x: px, y: y(px))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        var down = CGAffineTransform(translationX: 0, y: -1.2)
        shade.path = path.copy(using: &down)
        core.path = path
        var up = CGAffineTransform(translationX: 0, y: 0.35)
        shine.path = path.copy(using: &up)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
