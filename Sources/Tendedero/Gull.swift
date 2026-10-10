import AppKit
import QuartzCore

// MARK: - Pictures

/// The seagull, an adult herring gull facing right. In flight it is a
/// dozen moments of a wingbeat seen from three heights; standing, it is
/// taken apart into a body, a head and two legs, so the head can glance
/// about, the legs can step and the body can breathe on its own. Drawn once
/// per display scale, off the main thread: bright white plumage with a fine
/// texture of feathers and soft edges, lit from above with the belly in a
/// light cool shade, a pale gray back of overlapping feathers, black
/// wingtips with white spots, a yellow bill with its red spot.
final class GullPictures: @unchecked Sendable {
    struct Picture {
        let image: CGImage?
        /// Where it was drawn, around its anchor, in points, y down.
        let rect: CGRect
    }

    /// The bird's size: 1 is about 47 points from tail to bill.
    static let size: CGFloat = 1.2
    /// The body's middle in flight is this far above the feet.
    static let lift: CGFloat = 15 * size
    /// Moments in one wingbeat.
    static let phases = 12

    /// The heights it is seen from in flight: a little from above, about
    /// level, and from below.
    enum View: Int, CaseIterable {
        case above, level, below
        var camera: Camera {
            switch self {
            case .above: Camera(yaw: 0.5, rise: 0.42)
            case .level: Camera(yaw: 0.36, rise: 0.06)
            case .below: Camera(yaw: 0.24, rise: -0.6)
            }
        }
    }

    struct Camera {
        /// How much of the near side is turned towards us.
        let yaw: CGFloat
        /// How far above the bird we are, negative below it.
        let rise: CGFloat
    }

    /// Standing in profile, or turned three-quarters towards you.
    enum Turn: Int, CaseIterable { case profile, turned }
    enum Bill: CaseIterable { case closed, open, blink }

    /// Where the parts join, unscaled, y down, from the feet.
    struct Joints {
        let neck: CGPoint
        let nearHip: CGPoint
        let farHip: CGPoint
    }

    static func joints(_ turn: Turn) -> Joints {
        switch turn {
        case .profile: Joints(neck: CGPoint(x: 7.2, y: -27.4), nearHip: CGPoint(x: -1.6, y: -10.2), farHip: CGPoint(x: 2.4, y: -10.6))
        case .turned: Joints(neck: CGPoint(x: 5.0, y: -27.4), nearHip: CGPoint(x: -2.4, y: -10.2), farHip: CGPoint(x: 1.6, y: -10.6))
        }
    }

    let flap: [View: [Picture]]
    let flapLegs: [Picture]
    let glide: [View: Picture]
    let glideLegs: Picture
    /// The body with its folded wings, its feet at the anchor; ruffled, the
    /// wing is lifted a little and the feathers stand up.
    let body: [Turn: [Bool: Picture]]
    /// The head on a short neck, anchored where the neck meets the body.
    let head: [Turn: [Bill: Picture]]
    let nearLeg: Picture
    let farLeg: Picture

    @MainActor private static var cache: [CGFloat: GullPictures] = [:]
    @MainActor private static var waiting: [CGFloat: [(GullPictures) -> Void]] = [:]

    /// The pictures for a display scale, drawn in the background the first
    /// time.
    @MainActor static func at(scale: CGFloat, _ done: @escaping (GullPictures) -> Void) {
        if let p = cache[scale] { return done(p) }
        if waiting[scale] != nil { waiting[scale]?.append(done); return }
        waiting[scale] = [done]
        DispatchQueue.global(qos: .userInitiated).async {
            let p = GullPictures(scale: scale)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cache[scale] = p
                    let calls = waiting.removeValue(forKey: scale) ?? []
                    calls.forEach { $0(p) }
                }
            }
        }
    }

    /// The pictures take a few megabytes; between visits they are let go.
    @MainActor static func forget() { cache = [:] }

    init(scale: CGFloat) {
        let k = Self.size
        let flightRect = CGRect(x: -48, y: -54, width: 86, height: 106).scaled(k)
        func draw(_ rect: CGRect, shadow: Bool = true, _ body: @escaping (CGContext) -> Void) -> Picture {
            let image = Sprite.draw(rect, scale: scale) { ctx in
                if shadow {
                    ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 3 * scale,
                                  color: Sprite.rgba(0, 0, 0, 0.24))
                }
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.scaleBy(x: k, y: k)
                body(ctx)
                ctx.endTransparencyLayer()
            }
            // A touch of softness, so the edges read like feathers, not ink.
            return Picture(image: image.flatMap { Sprite.blurred($0, radius: 0.32 * scale) } ?? image,
                           rect: Sprite.aligned(rect, scale: scale))
        }
        let n = Self.phases
        var flap: [View: [Picture]] = [:], glide: [View: Picture] = [:]
        for view in View.allCases {
            flap[view] = (0..<n).map { i in draw(flightRect) { Self.flight($0, view, phase: Double(i) / Double(n), legs: false) } }
            glide[view] = draw(flightRect) { Self.flight($0, view, phase: nil, legs: false) }
        }
        self.flap = flap
        self.glide = glide
        flapLegs = (0..<n).map { i in draw(flightRect) { Self.flight($0, .above, phase: Double(i) / Double(n), legs: true) } }
        glideLegs = draw(flightRect) { Self.flight($0, .above, phase: nil, legs: true) }

        var body: [Turn: [Bool: Picture]] = [:], head: [Turn: [Bill: Picture]] = [:]
        for turn in Turn.allCases {
            let t = CGFloat(turn.rawValue)
            let bodyRect = CGRect(x: -33, y: -36, width: 50, height: 30).scaled(k)
            body[turn] = [false: draw(bodyRect) { Self.body($0, turn: t, ruffled: false) },
                          true: draw(bodyRect) { Self.body($0, turn: t, ruffled: true) }]
            let headRect = CGRect(x: -9, y: -11, width: 24, height: 17).scaled(k)
            var bills: [Bill: Picture] = [:]
            for bill in Bill.allCases {
                // The head casts no shadow of its own: the body's is enough.
                bills[bill] = draw(headRect, shadow: false) { Self.head($0, turn: t, bill: bill) }
            }
            head[turn] = bills
        }
        self.body = body
        self.head = head
        let legRect = CGRect(x: -3, y: -1, width: 9, height: 13).scaled(k)
        nearLeg = draw(legRect) { Self.leg($0, length: 10.2, color: Self.leg) }
        farLeg = draw(legRect) { Self.leg($0, length: 10.6, color: Self.legShade) }
    }

    // MARK: Colors

    private static let white = Sprite.rgba(253, 253, 251, 1)
    private static let shade = Sprite.rgba(184, 194, 208, 1)
    private static let rim = Sprite.rgba(120, 132, 148, 1)
    private static let mantleDark = Sprite.rgba(162, 173, 186, 1)
    private static let mantleLight = Sprite.rgba(192, 202, 212, 1)
    private static let underwing = Sprite.rgba(242, 244, 247, 1)
    private static let underwingShade = Sprite.rgba(204, 212, 222, 1)
    private static let black = Sprite.rgba(26, 26, 30, 1)
    private static let blackSheen = Sprite.rgba(74, 76, 84, 1)
    private static let billBase = Sprite.rgba(246, 206, 70, 1)
    private static let billTip = Sprite.rgba(232, 174, 38, 1)
    private static let gonys = Sprite.rgba(214, 52, 34, 1)
    private static let leg = Sprite.rgba(230, 168, 156, 1)
    private static let legShade = Sprite.rgba(196, 130, 122, 1)

    // MARK: Shared parts

    /// White plumage over the union of `parts`: lit from above, the lower
    /// side in a light cool shade, a fine texture of small feathers, and a
    /// faint darker rim so it reads on a light desktop. `rimClip`, when
    /// given, keeps the rim to that area.
    private static func plumage(_ ctx: CGContext, _ parts: [CGPath], shadeFrom: CGFloat, shadeTo: CGFloat,
                                depth: CGFloat = 0.42, seed: Int, rimClip: CGPath? = nil) {
        var union = parts[0]
        for p in parts.dropFirst() { union = union.union(p) }
        Sprite.fill(ctx, union, white)
        Sprite.clipped(ctx, union) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: shadeFrom), to: CGPoint(x: 0, y: shadeTo),
                          [(0, Sprite.rgba(255, 255, 255, 0)), (0.6, alpha(shade, depth * 0.4)), (1, alpha(shade, depth))])
            feathers(ctx, in: union.boundingBoxOfPath, strength: 1, seed: seed)
            let edge = {
                Sprite.stroke(ctx, union, alpha(rim, 0.1), width: 3.4)
                Sprite.stroke(ctx, union, alpha(rim, 0.22), width: 1.1)
            }
            if let rimClip { Sprite.clipped(ctx, rimClip, edge) } else { edge() }
        }
    }

    /// Small overlapping feathers, just hinted: the soft lower edge of each,
    /// a little shade under a little light, in rows like scales.
    private static func feathers(_ ctx: CGContext, in box: CGRect, strength: CGFloat, seed: Int) {
        var rnd = SeededRandom(seed: seed)
        var y = box.minY + 0.6, row = 0
        while y < box.maxY {
            var x = box.minX + (row % 2 == 0 ? 0 : 1.15)
            while x < box.maxX {
                let c = CGPoint(x: x + (rnd.nextCG() - 0.5) * 0.7, y: y + (rnd.nextCG() - 0.5) * 0.4)
                let r = 1.05 + rnd.nextCG() * 0.5
                let arc = CGMutablePath()
                arc.addArc(center: c, radius: r, startAngle: 0.35, endAngle: .pi - 0.35, clockwise: false)
                Sprite.stroke(ctx, arc, Sprite.rgba(110, 122, 140, 0.05 * strength), width: 0.4)
                var up = CGAffineTransform(translationX: 0, y: -0.35)
                if let light = arc.copy(using: &up) {
                    Sprite.stroke(ctx, light, Sprite.rgba(255, 255, 255, 0.5 * strength), width: 0.3)
                }
                x += 2.3
            }
            y += 1.55
            row += 1
        }
    }

    private static func alpha(_ c: CGColor, _ a: CGFloat) -> CGColor { c.copy(alpha: a) ?? c }

    /// The head, facing right, its middle at the origin: a sloping forehead,
    /// a rounded crown and the throat running into the neck.
    private static func headShape(_ t: CGAffineTransform) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 4.6, y: -0.5), transform: t)
        p.addQuadCurve(to: CGPoint(x: 0.6, y: -4.3), control: CGPoint(x: 3.6, y: -3.9), transform: t)
        p.addQuadCurve(to: CGPoint(x: -4.4, y: -2.1), control: CGPoint(x: -2.9, y: -4.7), transform: t)
        p.addQuadCurve(to: CGPoint(x: -4.4, y: 2.8), control: CGPoint(x: -5.6, y: 0.4), transform: t)
        p.addQuadCurve(to: CGPoint(x: 2.6, y: 3.9), control: CGPoint(x: -0.8, y: 4.6), transform: t)
        p.addQuadCurve(to: CGPoint(x: 4.6, y: 1.4), control: CGPoint(x: 4.3, y: 3.2), transform: t)
        p.closeSubpath()
        return p
    }

    /// The bill and the eye, over a head already drawn. `reach` shortens
    /// the bill when the head is turned towards us.
    private static func face(_ ctx: CGContext, _ t: CGAffineTransform, open: CGFloat, blink: Bool, reach: CGFloat = 1) {
        ctx.saveGState()
        ctx.concatenate(t)
        let len = 8.2 * reach
        // The lower mandible turns open about the gape.
        ctx.saveGState()
        ctx.translateBy(x: 4.2, y: 1.0)
        ctx.rotate(by: open)
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: 0, y: -0.2))
        lower.addLine(to: CGPoint(x: len - 1.0, y: -0.25))
        lower.addQuadCurve(to: CGPoint(x: len * 0.68, y: 1.25), control: CGPoint(x: len - 1.4, y: 1.15))
        lower.addQuadCurve(to: CGPoint(x: 0, y: 1.0), control: CGPoint(x: len * 0.3, y: 0.95))
        lower.closeSubpath()
        Sprite.clipped(ctx, lower) {
            Sprite.linear(ctx, from: .zero, to: CGPoint(x: len, y: 0), [(0, billBase), (1, billTip)])
            Sprite.fill(ctx, Sprite.ellipse(len * 0.7, 0.55, 1.0 * reach + 0.2, 0.75), gonys)
            Sprite.linear(ctx, from: CGPoint(x: 0, y: -0.3), to: CGPoint(x: 0, y: 1.3),
                          [(0, Sprite.rgba(255, 255, 255, 0)), (1, Sprite.rgba(150, 100, 20, 0.35))])
        }
        ctx.restoreGState()
        let upper = CGMutablePath()
        upper.move(to: CGPoint(x: 3.9, y: -0.9))
        upper.addQuadCurve(to: CGPoint(x: 4.2 + len - 0.4, y: -0.35), control: CGPoint(x: 4.2 + len * 0.55, y: -1.5))
        upper.addQuadCurve(to: CGPoint(x: 4.2 + len - 0.9, y: 1.35), control: CGPoint(x: 4.2 + len + 0.35, y: 0.6))
        upper.addQuadCurve(to: CGPoint(x: 4.2 + len - 1.6, y: 0.8), control: CGPoint(x: 4.2 + len - 1.1, y: 0.8))
        upper.addLine(to: CGPoint(x: 4.3, y: 1.05))
        upper.closeSubpath()
        Sprite.clipped(ctx, upper) {
            Sprite.linear(ctx, from: CGPoint(x: 4, y: 0), to: CGPoint(x: 4.2 + len, y: 0),
                          [(0, billBase), (0.8, billTip), (1, Sprite.rgba(244, 222, 140, 1))])
            Sprite.linear(ctx, from: CGPoint(x: 0, y: -1.2), to: CGPoint(x: 0, y: 1.1),
                          [(0, Sprite.rgba(255, 250, 220, 0.5)), (0.5, Sprite.rgba(255, 255, 255, 0)), (1, Sprite.rgba(150, 100, 20, 0.3))])
        }
        let gape = CGMutablePath()
        gape.move(to: CGPoint(x: 4.0, y: 0.95))
        gape.addLine(to: CGPoint(x: 4.2 + len * 0.62, y: 0.82))
        Sprite.stroke(ctx, gape, Sprite.rgba(120, 80, 20, 0.55), width: 0.3)
        let nostril = CGMutablePath()
        nostril.move(to: CGPoint(x: 4.2 + len * 0.3, y: -0.35))
        nostril.addLine(to: CGPoint(x: 4.2 + len * 0.48, y: -0.3))
        Sprite.stroke(ctx, nostril, Sprite.rgba(120, 80, 20, 0.45), width: 0.3)
        // The eye: a pale iris, a small pupil, a thin orange ring.
        let eye = CGPoint(x: 1.3, y: -1.2)
        if blink {
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: eye.x - 1, y: eye.y))
            lid.addQuadCurve(to: CGPoint(x: eye.x + 1, y: eye.y), control: CGPoint(x: eye.x, y: eye.y + 0.6))
            Sprite.stroke(ctx, lid, Sprite.rgba(110, 116, 124, 0.8), width: 0.4)
        } else {
            Sprite.fill(ctx, Sprite.ellipse(eye.x, eye.y, 0.95, 0.9), Sprite.rgba(238, 224, 160, 1))
            Sprite.stroke(ctx, Sprite.ellipse(eye.x, eye.y, 1.0, 0.95), Sprite.rgba(222, 112, 62, 0.9), width: 0.3)
            Sprite.fill(ctx, Sprite.ellipse(eye.x + 0.08, eye.y, 0.42, 0.42), Sprite.rgba(18, 18, 20, 1))
            Sprite.fill(ctx, Sprite.ellipse(eye.x + 0.25, eye.y - 0.25, 0.17, 0.17), Sprite.rgba(255, 255, 255, 0.95))
        }
        ctx.restoreGState()
    }

    // MARK: Standing

    /// The body with its folded wing, feet at (0, 0), without head or legs.
    private static func body(_ ctx: CGContext, turn: CGFloat, ruffled: Bool) {
        // Turned towards us the body is shorter and the breast fuller.
        let squeeze = CGAffineTransform(scaleX: 1 - 0.26 * turn, y: 1)
        let body = CGMutablePath()
        let fluff: CGFloat = ruffled ? 0.6 : 0
        body.move(to: CGPoint(x: 6, y: -31), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 2, y: -26), control: CGPoint(x: 3.2, y: -29.5), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: -12, y: -22 - fluff), control: CGPoint(x: -4, y: -23.8 - fluff), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: -24.5, y: -16.6), control: CGPoint(x: -19, y: -19.6 - fluff), transform: squeeze)
        body.addLine(to: CGPoint(x: -25, y: -14.6), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: -11.5, y: -11), control: CGPoint(x: -18, y: -12.2), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 4.5, y: -10.2 + fluff * 0.5), control: CGPoint(x: -3, y: -8.6 + fluff), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 12, y: -19.5), control: CGPoint(x: 12 + fluff, y: -12.2), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 12.5, y: -28), control: CGPoint(x: 12.8 + fluff, y: -24), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 6, y: -31), control: CGPoint(x: 10, y: -32.5), transform: squeeze)
        body.closeSubpath()
        var parts: [CGPath] = [body]
        if turn > 0 { parts.append(Sprite.ellipse(5.5, -18.5, 6.4 * turn + 0.1, 8.4)) }
        plumage(ctx, parts, shadeFrom: -22, shadeTo: -9, seed: 11 + Int(turn))

        ctx.saveGState()
        ctx.concatenate(squeeze)
        if ruffled {
            // The wing lifted a little off the back, as when preening.
            ctx.translateBy(x: -2, y: -21)
            ctx.rotate(by: -0.07)
            ctx.translateBy(x: 2, y: 20.2)
        }
        // The primaries, black, crossed over the tail, with white spots.
        for (i, tip) in [CGPoint(x: -29.6, y: -16.8), CGPoint(x: -28.3, y: -16.0), CGPoint(x: -26.9, y: -15.4),
                         CGPoint(x: -25.3, y: -15.0), CGPoint(x: -23.5, y: -14.7)].enumerated().reversed() {
            let base = CGPoint(x: -12 + CGFloat(i) * 0.3, y: -19.6 + CGFloat(i) * 1.0)
            let f = CGMutablePath()
            f.move(to: CGPoint(x: base.x, y: base.y - 1.1))
            f.addQuadCurve(to: tip, control: CGPoint(x: (base.x + tip.x) / 2, y: base.y - 1.3))
            f.addQuadCurve(to: CGPoint(x: base.x, y: base.y + 1.0), control: CGPoint(x: (base.x + tip.x) / 2, y: base.y + 0.9))
            f.closeSubpath()
            Sprite.clipped(ctx, f) {
                Sprite.linear(ctx, from: CGPoint(x: base.x, y: base.y - 1), to: CGPoint(x: base.x, y: base.y + 1),
                              [(0, blackSheen), (0.45, black), (1, black)])
            }
            // The shaft, just catching the light.
            let shaft = CGMutablePath()
            shaft.move(to: CGPoint(x: base.x - 2, y: base.y - 0.1))
            shaft.addQuadCurve(to: CGPoint(x: tip.x + 1.5, y: tip.y), control: CGPoint(x: (base.x + tip.x) / 2, y: base.y - 0.4))
            Sprite.stroke(ctx, shaft, Sprite.rgba(120, 124, 132, 0.35), width: 0.2)
            if i < 2 {
                Sprite.fill(ctx, Sprite.ellipse(tip.x + 1.6, tip.y + 0.1, 1.0, 0.55), Sprite.rgba(250, 250, 248, 0.95))
            }
        }
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 8.5, y: -23.5))
        wing.addQuadCurve(to: CGPoint(x: -6, y: -25.6), control: CGPoint(x: 1, y: -26.6))
        wing.addQuadCurve(to: CGPoint(x: -17.5, y: -19.4), control: CGPoint(x: -13.5, y: -24.2))
        wing.addLine(to: CGPoint(x: -13, y: -14.6))
        wing.addQuadCurve(to: CGPoint(x: 6.5, y: -17.8), control: CGPoint(x: -3.5, y: -13.4))
        wing.addQuadCurve(to: CGPoint(x: 8.5, y: -23.5), control: CGPoint(x: 8.8, y: -20.5))
        wing.closeSubpath()
        // A soft shadow the wing casts on the flank.
        Sprite.clipped(ctx, body) {
            Sprite.fill(ctx, Sprite.ellipse(-3, -14.2, 13, 2.2), Sprite.rgba(130, 142, 160, 0.12))
        }
        Sprite.clipped(ctx, wing) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: -26), to: CGPoint(x: 0, y: -14),
                          [(0, mantleDark), (0.6, mantleLight), (1, Sprite.rgba(204, 212, 220, 1))])
            // Overlapping feathers in rows, each with a pale edge and its
            // base in a little shade under the one above.
            var rnd = SeededRandom(seed: ruffled ? 7 : 5)
            for (row, (from, to, y0, size)) in [(CGPoint(x: 6, y: 0), CGPoint(x: -14, y: 0), CGFloat(-23.8), CGFloat(2.4)),
                                                (CGPoint(x: 5, y: 0), CGPoint(x: -15, y: 0), CGFloat(-21.2), CGFloat(2.9)),
                                                (CGPoint(x: 3, y: 0), CGPoint(x: -15, y: 0), CGFloat(-18.4), CGFloat(3.4))].enumerated() {
                var x = from.x
                while x > to.x {
                    let c = CGPoint(x: x + (rnd.nextCG() - 0.5) * 0.6, y: y0 + CGFloat(row) * 0.2 - x * 0.12 * (row == 0 ? 0.4 : 0.25)
                                    + (ruffled ? (rnd.nextCG() - 0.5) * 0.8 : 0))
                    let feather = Sprite.ellipse(c.x, c.y, size * 0.8, size * 0.55, rotation: -0.25)
                    Sprite.stroke(ctx, feather, Sprite.rgba(120, 132, 148, 0.16), width: 0.4)
                    let edge = CGMutablePath()
                    edge.addArc(center: c, radius: size * 0.62, startAngle: 0.5, endAngle: 2.3, clockwise: false)
                    Sprite.stroke(ctx, edge, Sprite.rgba(232, 238, 244, 0.55), width: 0.45)
                    x -= size * 1.15
                }
            }
            Sprite.stroke(ctx, wing, Sprite.rgba(118, 130, 146, 0.32), width: 1.0)
        }
        // The white edges of the tertials.
        let tertials = CGMutablePath()
        tertials.move(to: CGPoint(x: -12.6, y: -15.2))
        tertials.addQuadCurve(to: CGPoint(x: 4.2, y: -17.6), control: CGPoint(x: -3.5, y: -14.2))
        Sprite.stroke(ctx, tertials, Sprite.rgba(253, 253, 251, 0.95), width: 1.3)
        ctx.restoreGState()
    }

    /// The head on a short neck, the neck's base at (0, 0).
    private static func head(_ ctx: CGContext, turn: CGFloat, bill: Bill) {
        let center = CGPoint(x: 2.6 - turn * 1.4, y: -3.0)
        let t = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: 1 - 0.18 * turn, y: 1)
        let neck = Sprite.ellipse(0.4, 0.2, 3.8, 4.2, rotation: 0.3)
        // The rim only around the head: the neck runs into the body.
        let rimArea = Sprite.ellipse(center.x + 0.6, center.y - 0.6, 6.2, 5.2)
        plumage(ctx, [headShape(t), neck], shadeFrom: center.y - 2, shadeTo: center.y + 6, depth: 0.32,
                seed: 3 + Int(turn), rimClip: rimArea)
        face(ctx, t, open: bill == .open ? 0.42 : 0, blink: bill == .blink, reach: 1 - 0.38 * turn)
    }

    /// A leg hanging from the hip at (0, 0): the tarsus and a webbed foot.
    private static func leg(_ ctx: CGContext, length: CGFloat, color: CGColor) {
        let foot = CGPoint(x: -0.6, y: length)
        let p = CGMutablePath()
        p.move(to: .zero)
        p.addLine(to: foot)
        Sprite.stroke(ctx, p, color, width: 1.45)
        let web = CGMutablePath()
        web.move(to: CGPoint(x: foot.x - 1.4, y: foot.y - 0.2))
        web.addLine(to: CGPoint(x: foot.x + 4.4, y: foot.y - 0.3))
        web.addLine(to: CGPoint(x: foot.x + 3.5, y: foot.y + 0.7))
        web.addLine(to: CGPoint(x: foot.x - 0.6, y: foot.y + 0.6))
        web.closeSubpath()
        Sprite.fill(ctx, web, color)
        // Light on the front of the leg.
        let shine = CGMutablePath()
        shine.move(to: CGPoint(x: 0.4, y: 0.5))
        shine.addLine(to: CGPoint(x: foot.x + 0.4, y: foot.y - 1))
        Sprite.stroke(ctx, shine, Sprite.rgba(255, 220, 210, 0.45), width: 0.4)
    }

    // MARK: Flying

    /// A flying gull, the middle of its body at (0, 0). `phase` runs through
    /// one wingbeat from wings high; nil is a glide.
    private static func flight(_ ctx: CGContext, _ view: View, phase: Double?, legs: Bool) {
        let cam = view.camera
        let arm: CGFloat, hand: CGFloat, fold: CGFloat
        if let phase {
            // A quicker downstroke and a slower upstroke with the hand folded.
            let a = 2 * Double.pi * phase
            let c = CGFloat(cos(a + 0.35 * sin(a)))
            arm = 0.36 + 0.82 * c
            hand = arm + 0.3 * c - 0.12
            fold = max(0, CGFloat(-sin(a)))
        } else {
            arm = 0.14
            hand = -0.16
            fold = 0
        }
        wing(ctx, cam, near: false, arm: arm, hand: hand, fold: fold)
        if legs {
            for (hip, foot, far) in [(CGPoint(x: -3.5, y: 3.2), CGPoint(x: -9, y: 11.2), true),
                                     (CGPoint(x: -1.5, y: 3.8), CGPoint(x: -6.4, y: 12.2), false)] {
                let p = CGMutablePath()
                p.move(to: hip)
                p.addLine(to: foot)
                Sprite.stroke(ctx, p, far ? legShade : leg, width: 1.4)
                let web = CGMutablePath()
                web.move(to: foot)
                web.addLine(to: CGPoint(x: foot.x + 3.2, y: foot.y + 1.6))
                web.addLine(to: CGPoint(x: foot.x + 0.8, y: foot.y + 2.4))
                web.closeSubpath()
                Sprite.fill(ctx, web, far ? legShade : leg)
            }
        }
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 14.5, y: -5.8))
        body.addQuadCurve(to: CGPoint(x: 10.5, y: -7.6), control: CGPoint(x: 13, y: -7.6))
        body.addQuadCurve(to: CGPoint(x: 6, y: -4.6), control: CGPoint(x: 8, y: -7.4))
        body.addQuadCurve(to: CGPoint(x: -8, y: -3.6), control: CGPoint(x: 0, y: -4.6))
        body.addQuadCurve(to: CGPoint(x: -17, y: -2.2), control: CGPoint(x: -12, y: -3.2))
        body.addLine(to: CGPoint(x: -22.5, y: -1.5))
        body.addQuadCurve(to: CGPoint(x: -22.5, y: 1.5), control: CGPoint(x: -23.3, y: 0))
        body.addLine(to: CGPoint(x: -16, y: 2.5))
        body.addQuadCurve(to: CGPoint(x: -4, y: 5.4), control: CGPoint(x: -10, y: 5.2))
        body.addQuadCurve(to: CGPoint(x: 8, y: 1.8), control: CGPoint(x: 4, y: 5.2))
        body.addQuadCurve(to: CGPoint(x: 13.8, y: -2.4), control: CGPoint(x: 12, y: 0.6))
        body.addQuadCurve(to: CGPoint(x: 14.5, y: -5.8), control: CGPoint(x: 15.4, y: -4.2))
        body.closeSubpath()
        // Seen from below, more of it is the shaded underside.
        let from: CGFloat = cam.rise < 0 ? -8 : -5, depth: CGFloat = cam.rise < 0 ? 0.55 : 0.42
        plumage(ctx, [body], shadeFrom: from, shadeTo: 5.5, depth: depth, seed: 21)
        // The gray back shows from above.
        if cam.rise > 0.2 {
            let back = CGMutablePath()
            back.move(to: CGPoint(x: 5, y: -4.4))
            back.addQuadCurve(to: CGPoint(x: -12, y: -3.0), control: CGPoint(x: -3, y: -5.2))
            back.addQuadCurve(to: CGPoint(x: 4, y: -2.6), control: CGPoint(x: -4, y: -2.2))
            back.closeSubpath()
            Sprite.fill(ctx, back, alpha(mantleLight, 0.8))
        }
        face(ctx, CGAffineTransform(translationX: 10.6, y: -4.6).scaledBy(x: 0.95, y: 0.95), open: 0, blink: false)
        wing(ctx, cam, near: true, arm: arm, hand: hand, fold: fold)
    }

    /// One wing, worked out in 3D and seen through `cam`: a broad inner
    /// wing and a hand of six separate primaries, gray above with a white
    /// trailing edge, white below, black at the tips with white spots.
    private static func wing(_ ctx: CGContext, _ cam: Camera, near: Bool, arm: CGFloat, hand: CGFloat, fold: CGFloat) {
        let L: CGFloat = 36
        let side: CGFloat = near ? 1 : -1
        typealias V = (x: CGFloat, y: CGFloat, z: CGFloat)
        func project(_ v: V) -> CGPoint { CGPoint(x: v.x + cam.yaw * v.y, y: -(v.z - cam.rise * v.y)) }
        let shoulder: V = (2, 0, 2.2)
        let armDir: V = (-0.22, side * cos(arm), sin(arm))
        let handDir: V = (-0.62 - 0.3 * fold, side * cos(hand), sin(hand))
        let handLength = 1 - 0.32 * fold
        let wristAt: CGFloat = 0.45
        let wrist: V = (shoulder.x + armDir.x * wristAt * L, shoulder.y + armDir.y * wristAt * L,
                        shoulder.z + armDir.z * wristAt * L)
        func point(_ s: CGFloat, _ c: CGFloat) -> CGPoint {
            var v: V
            if s <= wristAt {
                v = (shoulder.x + armDir.x * s * L, shoulder.y + armDir.y * s * L, shoulder.z + armDir.z * s * L)
            } else {
                let d = (s - wristAt) * L * handLength
                v = (wrist.x + handDir.x * d, wrist.y + handDir.y * d, wrist.z + handDir.z * d)
            }
            v.x -= c * L
            return project(v)
        }
        func smooth(_ pts: [CGPoint], closed: Bool) -> CGPath {
            let path = CGMutablePath()
            guard pts.count > 2 else { return path }
            path.move(to: pts[0])
            for i in 1..<pts.count - 1 {
                let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[i])
            }
            path.addLine(to: pts[pts.count - 1])
            if closed { path.closeSubpath() }
            return path
        }
        // Which side faces us, and how the light from above falls on it.
        let facing = near ? -sin(arm) + cam.rise * cos(arm) : sin(arm) + cam.rise * cos(arm)
        let under = min(1, max(0, 0.5 - facing * 4))
        let lit = max(0, cos(arm)) * 0.8 + 0.2
        let top = mix(mantleDark, mantleLight, lit * (near ? 1 : 0.6))
        let below = mix(underwingShade, underwing, near ? 0.8 : 0.4)
        let base = mix(top, below, under)

        // The primaries, outermost last so it lies on top.
        for i in (0..<6).reversed() {
            let fi = CGFloat(i)
            let b0 = (s: 0.66, c: 0.03 + fi * 0.042)
            let tip = (s: 1.0 - fi * 0.045, c: 0.13 + fi * 0.045)
            let w: CGFloat = 0.046
            let mid = (s: b0.s + (tip.s - b0.s) * 0.62, c: b0.c + (tip.c - b0.c) * 0.62)
            let pts = [point(b0.s, b0.c - w), point(mid.s, mid.c - w * 0.9), point(tip.s - 0.015, tip.c - w * 0.4),
                       point(tip.s, tip.c), point(tip.s - 0.015, tip.c + w * 0.4), point(mid.s, mid.c + w * 0.9),
                       point(b0.s, b0.c + w)]
            let feather = smooth(pts, closed: true)
            Sprite.fill(ctx, feather, mix(black, blackSheen, under * 0.5))
            Sprite.stroke(ctx, feather, alpha(blackSheen, 0.7), width: 0.3)
            if i < 2 {
                let spot = point(tip.s - 0.04, tip.c)
                Sprite.fill(ctx, Sprite.ellipse(spot.x, spot.y, 0.9, 0.75), Sprite.rgba(250, 250, 248, 0.9))
            }
        }
        // The inner wing and the base of the hand.
        let lead: [(CGFloat, CGFloat)] = [(0, 0), (0.2, -0.02), (0.45, -0.05), (0.62, -0.02), (0.76, 0.04)]
        let trail: [(CGFloat, CGFloat)] = [(0.76, 0.3), (0.6, 0.34), (0.45, 0.37), (0.2, 0.36), (0, 0.33)]
        let plate = smooth((lead + trail).map { point($0.0, $0.1) }, closed: true)
        Sprite.fill(ctx, plate, base)
        Sprite.clipped(ctx, plate) {
            // Lighter towards the leading edge from above; the underside a
            // little brighter in its middle.
            let a = point(0.35, 0), b = point(0.35, 0.36)
            Sprite.linear(ctx, from: a, to: b, under < 0.5
                          ? [(0, Sprite.rgba(255, 255, 255, 0.2)), (0.6, Sprite.rgba(255, 255, 255, 0)), (1, Sprite.rgba(0, 0, 0, 0.05))]
                          : [(0, Sprite.rgba(255, 255, 255, 0.12)), (0.5, Sprite.rgba(255, 255, 255, 0.3)), (1, Sprite.rgba(120, 130, 145, 0.12))])
            // Rows of coverts along the wing, just hinted.
            for c in [0.1, 0.18] as [CGFloat] {
                let row = smooth([0.05, 0.25, 0.45, 0.62].map { point($0, c) }, closed: false)
                Sprite.stroke(ctx, row, under < 0.5 ? Sprite.rgba(230, 236, 242, 0.35) : Sprite.rgba(170, 180, 192, 0.18), width: 0.5)
            }
            // The white trailing edge on top, soft gray below.
            let edge = smooth(trail.map { point($0.0, $0.1 - 0.012) }, closed: false)
            Sprite.stroke(ctx, edge, under < 0.5 ? Sprite.rgba(252, 252, 250, 0.95) : Sprite.rgba(176, 186, 198, 0.4),
                          width: under < 0.5 ? 2.4 : 1.6)
            Sprite.stroke(ctx, plate, alpha(rim, 0.2), width: 1.3)
        }
    }

    private static func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        guard let ca = a.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              let cb = b.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              ca.count >= 4, cb.count >= 4 else { return a }
        let t = min(max(t, 0), 1)
        return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t,
                       blue: ca[2] + (cb[2] - ca[2]) * t, alpha: ca[3] + (cb[3] - ca[3]) * t)
    }
}

private extension CGRect {
    func scaled(_ k: CGFloat) -> CGRect { CGRect(x: minX * k, y: minY * k, width: width * k, height: height * k) }
}

// MARK: - Perches

/// Something a gull can stand on: the line's rope or a garland's wire, as
/// points along it in screen coordinates.
struct Perch {
    enum Kind: Equatable {
        case rope, garland(UUID)
    }

    let kind: Kind
    /// Along it, left to right.
    let points: [CGPoint]
    /// Kept clear of the ends.
    var margin: CGFloat = 40
    /// Spots taken already, like the pegs on the line.
    var avoid: [CGFloat] = []

    var minX: CGFloat { (points.first?.x ?? 0) + margin }
    var maxX: CGFloat { (points.last?.x ?? 0) - margin }

    func y(at x: CGFloat) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var lo = 0, hi = points.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].x <= x { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        return a.y + (b.y - a.y) * (x - a.x) / max(b.x - a.x, 0.001)
    }

    func canStand(at x: CGFloat) -> Bool {
        guard x >= minX, x <= maxX else { return false }
        let slope = (y(at: x + 6) - y(at: x - 6)) / 12
        return abs(slope) < 0.45 && avoid.allSatisfy { abs($0 - x) > 18 }
    }

    func randomSpot() -> CGFloat? {
        guard maxX > minX else { return nil }
        for _ in 0..<40 {
            let x = CGFloat.random(in: minX...maxX)
            if canStand(at: x) { return x }
        }
        return nil
    }

    /// The free spot nearest to `x`.
    func spot(near x: CGFloat) -> CGFloat? {
        guard maxX > minX else { return nil }
        let x = min(max(x, minX), maxX)
        for step in 0..<120 {
            for dir: CGFloat in [1, -1] {
                let c = x + dir * CGFloat(step) * 4
                if canStand(at: c) { return c }
            }
        }
        return nil
    }
}

// MARK: - Visits

/// Now and then a seagull flies over the desktop. Sometimes it only passes
/// by, more often it lands on the line, now and then on a garland, looks
/// around, preens, walks a little, and flies off. The rope sags under it
/// and swings when it lands or takes off; its wings stir the bulbs and the
/// candle flames. Double-click it and it follows the pointer until
/// double-clicked again. ⌥⌘G calls one or sends it away; pressed twice
/// quickly, the gull follows the pointer.
@MainActor
final class Seagulls {
    let line: Line
    let decorations: GarlandController
    private let linePanel: () -> NSWindow?
    private let lineRevealed: () -> Bool
    private var visit: GullVisit?
    private var timer: Timer?

    var isOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "gullsOff") }
        set {
            UserDefaults.standard.set(!newValue, forKey: "gullsOff")
            schedule()
            if !newValue { visit?.leave() }
        }
    }

    init(line: Line, decorations: GarlandController, linePanel: @escaping () -> NSWindow?, lineRevealed: @escaping () -> Bool) {
        self.line = line
        self.decorations = decorations
        self.linePanel = linePanel
        self.lineRevealed = lineRevealed
        schedule()
    }

    /// A visit every four to ten minutes.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isOn else { return }
        let t = Timer(timeInterval: .random(in: 240...600), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.arrive()
                self?.schedule()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var arriving = false

    /// A gull comes now, unless one is here already; `following`, it
    /// follows the pointer from the start.
    func arrive(following: Bool = false) {
        if let visit, visit.isLeaving { visit.end() }
        guard visit == nil, !arriving, let screen = GarlandController.lineScreen else { return }
        arriving = true
        GullPictures.at(scale: screen.backingScaleFactor) { [weak self] pictures in
            guard let self else { return }
            self.arriving = false
            guard self.visit == nil else { return }
            let v = GullVisit(screen: screen, world: self, pictures: pictures)
            self.visit = v
            v.onEnd = { [weak self, weak v] in
                if self?.visit === v { self?.visit = nil }
            }
            v.start()
            if following { v.toggleFollowing() }
        }
    }

    private var pressTimer: Timer?

    /// ⌥⌘G: once calls a gull, or sends away the one that is here; twice
    /// quickly, it follows the pointer, or stops following.
    func shortcutPressed() {
        if let t = pressTimer {
            t.invalidate()
            pressTimer = nil
            if let visit { visit.toggleFollowing() } else { arrive(following: true) }
            return
        }
        let t = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pressTimer = nil
                if let visit = self.visit, !visit.isLeaving { visit.leave() } else { self.arrive() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pressTimer = t
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        let on = ClosureMenuItem(L("Seagulls visit", "Visitas de gaviotas")) { [weak self] in
            guard let self else { return }
            self.isOn.toggle()
        }
        on.state = isOn ? .on : .off
        menu.addItem(on)
        let call = ClosureMenuItem(L("Call a seagull now", "Llamar a una gaviota")) { [weak self] in self?.arrive() }
        call.keyEquivalent = "g"
        call.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(call)
        menu.addItem(.separator())
        for text in [L("⌥⌘G calls a seagull or sends it away", "⌥⌘G llama a la gaviota o la espanta"),
                     L("⌥⌘G twice, or a double-click on it: it follows you", "⌥⌘G dos veces o doble clic: te sigue")] {
            let hint = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    // MARK: The world the gull lives in

    var lineWindow: NSWindow? { linePanel() }
    var lineIsDown: Bool { lineRevealed() && linePanel()?.isVisible == true }

    /// Everything on `screen` a gull could stand on.
    func perches(on screen: NSScreen) -> [Perch] {
        var result: [Perch] = []
        if let rope = rope(on: screen) { result.append(rope) }
        for wire in decorations.wires() {
            let pts = wire.points.filter { screen.frame.contains($0) }.sorted { $0.x < $1.x }
            guard pts.count > 10 else { continue }
            result.append(Perch(kind: .garland(wire.id), points: pts, margin: 24))
        }
        return result
    }

    /// The line's rope as it hangs now, if it is down on `screen`.
    func rope(on screen: NSScreen) -> Perch? {
        guard lineRevealed(), let panel = linePanel(), panel.isVisible,
              screen.frame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) else { return nil }
        let f = panel.frame, w = f.width
        let top = f.maxY - line.topOffset
        let pts = (0...200).map { i -> CGPoint in
            let x = CGFloat(i) / 200 * w
            return CGPoint(x: f.minX + x, y: top - RopeBend.restY(at: x, width: w))
        }
        let pegs = line.items.filter { !$0.falling }.map { f.minX + CGFloat($0.position) * w }
        return Perch(kind: .rope, points: pts, margin: 50, avoid: pegs)
    }

    /// A gull's weight pulls a perch down: `depth` points at `p`.
    func bend(_ kind: Perch.Kind, at p: CGPoint, depth: CGFloat) {
        switch kind {
        case .rope:
            guard let panel = linePanel() else { return }
            line.bendRope(at: p.x - panel.frame.minX, depth: depth)
        case .garland(let id):
            decorations.bend(id, at: p, depth: depth)
        }
    }

    /// Landing on or leaving the rope jolts the photos near it.
    func jolt(_ kind: Perch.Kind, at p: CGPoint, strength: Double) {
        guard kind == .rope, let panel = linePanel() else { return }
        line.jolt(at: p.x - panel.frame.minX, strength: strength)
    }

    func air(at p: CGPoint, velocity: CGVector) {
        decorations.feelAir(at: p, velocity: velocity)
    }
}

/// One gull on the screen, from the moment it flies in until it is gone.
/// It moves only while it is here, at up to 60 frames a second.
@MainActor
final class GullVisit: NSObject {
    var onEnd: (() -> Void)?

    private unowned let world: Seagulls
    private let screen: NSScreen
    private let window: GullWindow
    /// The bird in flight, one picture at a time.
    private let bird = CALayer()
    /// The bird standing, in parts.
    private let stander = CALayer()
    private let body = CALayer(), head = CALayer(), nearLeg = CALayer(), farLeg = CALayer()
    private let pictures: GullPictures
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var clock: CFTimeInterval = 0

    // Where it is, in screen coordinates: the middle of its body while it
    // flies, its feet while it stands.
    private var p = CGPoint.zero
    private var v = CGVector.zero
    private var facing: CGFloat = 1
    private var wingPhase = 0.0

    private enum Mode {
        case flying
        case standing
        /// Just pushed off: crouched, then up.
        case rising(since: CFTimeInterval)
    }
    private var mode = Mode.flying
    /// Points to fly through, then a spot to land on, or away if none.
    private var route: [CGPoint] = []
    private var landing: (perch: Perch, x: CGFloat)?
    private var perch: Perch?
    private var walkTo: CGFloat?
    private var walkSpeed: CGFloat = 40
    private var stride = 0.0
    // Standing: where the head is held and what the bill and body do. The
    // head turns quickly to where it looks and holds still there, as birds'
    // heads do; positive is the bill down.
    private var headAngle: CGFloat = 0
    private var headTarget: CGFloat = 0
    private var headBack = false
    private var nextGlance: CFTimeInterval = 0
    private var holdUntil: CFTimeInterval = 0
    private var blinkUntil: CFTimeInterval = 0
    private var nextBlink: CFTimeInterval = 0
    private var billOpenUntil: CFTimeInterval = 0
    private var preenUntil: CFTimeInterval = 0
    private var nibbleUntil: CFTimeInterval = 0
    private var nextNibble: CFTimeInterval = 0
    private var shakeUntil: CFTimeInterval = 0
    private var ruffledUntil: CFTimeInterval = 0
    private var crouchUntil: CFTimeInterval = 0
    /// Just landed: the wings are still up for a moment.
    private var touchdownUntil: CFTimeInterval = 0
    private var squawks = 0
    private var squawkAt: CFTimeInterval = 0
    /// How many times the pointer has frightened it off; the third time it
    /// does not come back.
    private var scares = 0
    private var lastDodge: CFTimeInterval = 0
    private var nextIdea: CFTimeInterval = 0
    private var leaveAt: CFTimeInterval = 0
    private var hops = 0
    private var glideUntil: CFTimeInterval = 0
    private var nextGlide: CFTimeInterval = 0
    private var gliding = false
    /// Where in a wingbeat the wings are about level, as in the glide.
    private static let levelPhase = 0.3
    private var flapUntil: CFTimeInterval = 0
    private var gone = false
    /// How high it is seen from in flight, changed a step at a time.
    private var view = GullPictures.View.above
    private var viewChanged: CFTimeInterval = 0
    /// Standing turned towards you, until then.
    private var turnedUntil: CFTimeInterval = 0
    private var calmPace = false

    /// Following the pointer, after a double-click.
    private var following = false
    private var pointerStillSince: CFTimeInterval = 0
    private var lastPointer: CGPoint?
    private var pointerSpeed: CGFloat = 0
    private var lastTurnToPointer: CFTimeInterval = 0

    // The perch under its weight, swinging until it is still.
    private var bent: (kind: Perch.Kind, at: CGPoint)?
    private var depth: CGFloat = 0
    private var depthSpeed: CGFloat = 0
    private var lastAir: CFTimeInterval = 0

    private var k: CGFloat { GullPictures.size }

    /// What it can stand on, looked up at most twice a second.
    private var perchCache: (perches: [Perch], at: CFTimeInterval)?
    private var perches: [Perch] {
        if let c = perchCache, clock - c.at < 0.5 { return c.perches }
        let p = world.perches(on: screen)
        perchCache = (p, clock)
        return p
    }

    init(screen: NSScreen, world: Seagulls, pictures: GullPictures) {
        self.screen = screen
        self.world = world
        self.pictures = pictures
        window = GullWindow(frame: screen.frame)
        super.init()
        window.gullView.onClick = { [weak self] count in self?.clicked(count) }
        for layer in [bird, stander, body, head, nearLeg, farLeg] { layer.contentsScale = screen.backingScaleFactor }
        // Standing it is four layers: the far leg, the near one, the body
        // and the head, each moving on its own.
        for part in [farLeg, nearLeg, body, head] { stander.addSublayer(part) }
        window.gullView.layer?.addSublayer(bird)
        window.gullView.layer?.addSublayer(stander)
    }

    func start() {
        let f = screen.frame
        let fromLeft = Bool.random()
        facing = fromLeft ? 1 : -1
        p = CGPoint(x: fromLeft ? f.minX - 60 : f.maxX + 60, y: f.minY + f.height * .random(in: 0.55...0.85))
        v = CGVector(dx: facing * 260, dy: -20)
        clock = CACurrentMediaTime()
        plan(arriving: true)
        window.orderFrontRegardless()
        keepLayered(now: clock, force: true)
        draw()
        let link = window.gullView.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// On its way off the screen, not coming back.
    var isLeaving: Bool { !following && landing == nil && perch == nil && route.count == 1 && !screen.frame.contains(route[0]) }

    /// Flies off now.
    func leave() {
        following = false
        if case .standing = mode { takeOff() }
        landing = nil
        route = [exitPoint()]
    }

    func end() {
        guard !gone else { return }
        gone = true
        link?.invalidate()
        link = nil
        if let bent { world.bend(bent.kind, at: bent.at, depth: 0) }
        window.orderOut(nil)
        GullPictures.forget()
        onEnd?()
    }

    // MARK: Plans

    /// Where to go next: a spot to land on, or just across and away.
    private func plan(arriving: Bool) {
        let perches = self.perches
        let f = screen.frame
        let land = arriving ? Double.random(in: 0..<1) < 0.75 : hops < 2 && Double.random(in: 0..<1) < 0.3
        if land, let choice = choosePerch(perches) {
            let y = choice.perch.y(at: choice.x)
            // Come round from above and behind the spot.
            let side: CGFloat = p.x < choice.x ? -1 : 1
            route = [CGPoint(x: choice.x + side * .random(in: 120...220), y: min(f.maxY - 60, y + .random(in: 90...160)))]
            landing = choice
            if !arriving { hops += 1 }
            return
        }
        landing = nil
        if !arriving {
            route = [exitPoint()]
            return
        }
        // Passing by: low over the candles or a garland now and then.
        var points: [CGPoint] = []
        let wires = perches.filter { if case .garland = $0.kind { return true } else { return false } }
        if let candles = world.decorations.candleTop, Double.random(in: 0..<1) < 0.5, f.contains(candles) {
            points.append(CGPoint(x: candles.x, y: candles.y + 30))
        } else if let wire = wires.randomElement(), let x = wire.randomSpot() {
            points.append(CGPoint(x: x, y: wire.y(at: x) + 26))
        } else {
            points.append(CGPoint(x: f.midX + .random(in: -200...200), y: f.minY + f.height * .random(in: 0.35...0.7)))
        }
        let out = p.x < f.midX ? f.maxX + 90 : f.minX - 90
        points.append(CGPoint(x: out, y: f.minY + f.height * .random(in: 0.5...0.9)))
        route = points
    }

    private func choosePerch(_ perches: [Perch]) -> (perch: Perch, x: CGFloat)? {
        // The line far more often than a garland.
        var weighted: [(Perch, Double)] = perches.map { p in
            switch p.kind {
            case .rope: (p, 4)
            case .garland: (p, 1)
            }
        }
        if let current = perch { weighted.removeAll { $0.0.kind == current.kind } }
        var total = weighted.reduce(0) { $0 + $1.1 }
        while total > 0 {
            var r = Double.random(in: 0..<total)
            for (i, (perch, w)) in weighted.enumerated() {
                r -= w
                if r < 0 {
                    if let x = perch.randomSpot() { return (perch, x) }
                    total -= w
                    weighted.remove(at: i)
                    break
                }
            }
        }
        return nil
    }

    private func exitPoint() -> CGPoint {
        let f = screen.frame
        let right = following ? Bool.random() : facing > 0
        return CGPoint(x: right ? f.maxX + 90 : f.minX - 90, y: min(f.maxY + 40, p.y + .random(in: 160...320)))
    }

    // MARK: Each frame

    // MARK: In front or behind

    private var layeredAt: CFTimeInterval = 0
    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)

    /// In front of the photos while it flies and while it stands on the
    /// line or on a garland. Where a window covers the garland it stands on,
    /// it goes behind that window with the garland. With the line put away
    /// it keeps to the desktop, behind the windows. Looked at a few times a
    /// second: the windows above are only asked about while on a garland.
    private func keepLayered(now: CFTimeInterval, force: Bool = false) {
        guard force || now - layeredAt > 0.25 else { return }
        layeredAt = now
        guard let line = world.lineWindow, line.isVisible else {
            if window.level != Self.desktopLevel { window.level = Self.desktopLevel }
            return
        }
        var front = true
        if case .garland? = perch?.kind, line.level > Self.desktopLevel, windowCovers(p) { front = false }
        let level = front ? line.level : Self.desktopLevel
        if window.level != level { window.level = level }
        // Same level as the line: it has to be ordered above it, and the
        // line may have been brought forward since.
        if front, window.level == line.level, window.orderedIndex > line.orderedIndex {
            window.order(.above, relativeTo: line.windowNumber)
        }
    }

    /// Whether an ordinary window of another app covers this point, in
    /// AppKit screen coordinates.
    private func windowCovers(_ point: CGPoint) -> Bool {
        guard let top = NSScreen.screens.first?.frame.maxY,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let at = CGPoint(x: point.x, y: top - point.y)
        let me = ProcessInfo.processInfo.processIdentifier
        return list.contains { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? Int32 != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { return false }
            return rect.contains(at)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(1.0 / 20, max(0.001, now - (lastTick == 0 ? now - 1.0 / 60 : lastTick)))
        lastTick = now
        clock = now
        watchPointer(dt: dt)
        switch mode {
        case .flying: fly(dt: CGFloat(dt))
        case .standing: stand(dt: CGFloat(dt))
        case .rising(let since):
            if now - since > 0.12 {
                mode = .flying
                flapUntil = now + 0.8
            }
        }
        swingPerch(dt: CGFloat(dt))
        guard !gone else { return }
        keepLayered(now: now)
        draw()
        // Standing still it only breathes, blinks and looks about: a calmer pace will do.
        var calm = false
        if case .standing = mode, walkTo == nil, bent == nil || abs(depthSpeed) < 2 { calm = !following }
        if calm != calmPace {
            calmPace = calm
            link.preferredFrameRateRange = calm ? CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
                                                : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
    }

    private func watchPointer(dt: Double) {
        let m = NSEvent.mouseLocation
        if let last = lastPointer {
            let d = hypot(m.x - last.x, m.y - last.y)
            pointerSpeed = pointerSpeed * 0.7 + CGFloat(Double(d) / dt) * 0.3
            if d > 1.5 { pointerStillSince = clock }
        }
        lastPointer = m
        window.catchMouse(hitRect().contains(m))
    }

    private func hitRect() -> CGRect {
        switch mode {
        case .standing: CGRect(x: p.x - 20 * k, y: p.y, width: 40 * k, height: 36 * k)
        default: CGRect(x: p.x - 24 * k, y: p.y - 14 * k, width: 48 * k, height: 26 * k)
        }
    }

    private func fly(dt: CGFloat) {
        if following {
            followFlying()
        } else {
            // A quick hand near it in the air: it swerves away.
            let m = NSEvent.mouseLocation
            let d = hypot(m.x - p.x, m.y - p.y)
            if d < 110, pointerSpeed > 500, clock - lastDodge > 0.6 {
                lastDodge = clock
                flapUntil = clock + 0.8
                v.dx += (p.x - m.x) / max(d, 1) * 320
                v.dy += max(120, (p.y - m.y) / max(d, 1) * 320)
            }
        }
        let target: CGPoint
        var final = false
        if let first = route.first {
            target = first
        } else if let landing {
            let y = landing.perch.y(at: landing.x) - (bent?.kind == landing.perch.kind ? depth : 0)
            target = CGPoint(x: landing.x, y: y + GullPictures.lift)
            final = true
        } else {
            // Nowhere to go: away, then gone.
            if !screen.frame.insetBy(dx: -70, dy: -70).contains(p) { end(); return }
            route = [exitPoint()]
            return
        }
        let dx = target.x - p.x, dy = target.y - p.y
        let dist = hypot(dx, dy)
        let approaching = final && dist < 120
        if approaching { gliding = false }
        let cruise: CGFloat = following ? 520 : 330
        let wanted = approaching ? min(cruise, max(40, dist * 2.4)) : min(cruise, max(120, dist * 2.2))
        let want = CGVector(dx: dx / max(dist, 1) * wanted, dy: dy / max(dist, 1) * wanted)
        let turn: CGFloat = approaching ? 5 : (following ? 3.4 : 2.2)
        v.dx += (want.dx - v.dx) * min(1, turn * dt)
        v.dy += (want.dy - v.dy) * min(1, turn * dt)
        p.x += v.dx * dt
        p.y += v.dy * dt
        if abs(v.dx) > 35 { facing = v.dx > 0 ? 1 : -1 }

        // Wings: beating while it climbs, slows down or has just set off;
        // otherwise a few beats and a glide, in turns.
        let speed = hypot(v.dx, v.dy)
        let mustBeat = v.dy > 60 || speed < 200 || approaching || clock < flapUntil
        if mustBeat {
            glideUntil = 0
            nextGlide = max(nextGlide, clock + 0.6)
        } else if !gliding, clock >= nextGlide {
            glideUntil = clock + .random(in: 0.9...2.2)
            nextGlide = glideUntil + .random(in: 0.8...1.6)
        }
        if gliding {
            if clock >= glideUntil {
                // Out of the glide where the beat passes level wings.
                gliding = false
                wingPhase = Self.levelPhase
            }
        } else {
            let rate = approaching || speed < 200 || v.dy > 60 ? 4.6 : 3.4
            let before = wingPhase
            wingPhase = (wingPhase + Double(dt) * rate).truncatingRemainder(dividingBy: 1)
            // Into a glide only as the wings pass level, so they do not jump.
            if clock < glideUntil, before < Self.levelPhase, wingPhase >= Self.levelPhase { gliding = true }
        }
        // The wings stir the air: the bird's own speed and the downwash of
        // each beat.
        if clock - lastAir > 1.0 / 30 {
            lastAir = clock
            let beat = gliding ? 0 : CGFloat(max(0, cos(2 * .pi * wingPhase)))
            world.air(at: p, velocity: CGVector(dx: v.dx * 1.4 + facing * beat * 260, dy: v.dy - beat * 420))
        }

        if route.first != nil, dist < 36 {
            route.removeFirst()
        } else if final, dist < 3 || (dist < 10 && speed < 70) {
            touchDown()
        }
    }

    private func touchDown() {
        guard let landing else { return }
        let x = landing.x
        let y = landing.perch.y(at: x)
        let impact = min(1.4, max(0.4, hypot(v.dx, v.dy) / 90))
        perch = landing.perch
        self.landing = nil
        mode = .standing
        p = CGPoint(x: x, y: y)
        v = .zero
        walkTo = nil
        // Wings up for a moment, then folded, the feathers settling.
        touchdownUntil = clock + 0.16
        crouchUntil = clock + 0.3
        ruffledUntil = clock + 0.7
        headTarget = 0.1
        headBack = false
        nextGlance = clock + 0.5
        nextBlink = clock + .random(in: 0.8...2)
        nextIdea = clock + .random(in: 1...2.5)
        leaveAt = clock + .random(in: 14...40)
        if bent?.kind != landing.perch.kind, let old = bent {
            world.bend(old.kind, at: old.at, depth: 0)
            bent = nil
            depth = 0
            depthSpeed = 0
        }
        bent = (landing.perch.kind, p)
        depthSpeed += 32 * impact
        world.jolt(landing.perch.kind, at: p, strength: 1.3 * Double(impact))
        // Settling the wings stirs the air once more.
        world.air(at: CGPoint(x: x, y: y + GullPictures.lift), velocity: CGVector(dx: facing * 520, dy: -300))
    }

    private func takeOff(away from: CGPoint? = nil) {
        guard case .standing = mode, let perch else { return }
        if let from { facing = from.x > p.x ? -1 : 1 }
        mode = .rising(since: clock)
        crouchUntil = clock + 0.12
        depthSpeed += 48
        world.jolt(perch.kind, at: p, strength: 1.5)
        p.y += GullPictures.lift
        v = CGVector(dx: facing * 170, dy: 230)
        wingPhase = 0.1
        self.perch = nil
        walkTo = nil
        preenUntil = 0
        squawks = 0
        world.air(at: p, velocity: CGVector(dx: facing * 600, dy: -380))
    }

    /// Frightened off by the pointer: up and away from it, round, and down
    /// again somewhere else on the line. The third time it leaves.
    private func startle(from m: CGPoint) {
        scares += 1
        takeOff(away: m)
        flapUntil = clock + 1.2
        let f = screen.frame
        let away: CGFloat = m.x > p.x ? -1 : 1
        if scares < 3, let spot = choosePerch(perches) {
            let up = CGPoint(x: min(max(p.x + away * .random(in: 160...280), f.minX + 60), f.maxX - 60),
                             y: min(f.maxY - 50, p.y + .random(in: 120...200)))
            let y = spot.perch.y(at: spot.x)
            let side: CGFloat = up.x < spot.x ? -1 : 1
            route = [up, CGPoint(x: spot.x + side * .random(in: 120...200), y: min(f.maxY - 60, y + .random(in: 80...140)))]
            landing = spot
        } else {
            landing = nil
            route = [exitPoint()]
        }
    }

    private func stand(dt: CGFloat) {
        guard let perch else { mode = .flying; return }
        // The line went up out of view: off it goes.
        if perch.kind == .rope, !world.lineIsDown {
            takeOff()
            plan(arriving: false)
            return
        }
        let m = NSEvent.mouseLocation
        let pointerNear = hypot(m.x - p.x, m.y - (p.y + 15 * k))
        if following {
            followStanding(perch)
        } else {
            // The pointer rushing at it frightens it off; only a slow,
            // careful hand gets close.
            if (pointerNear < 120 && pointerSpeed > 450) || (pointerNear < 60 && pointerSpeed > 220) {
                startle(from: m)
                return
            }
            if clock > leaveAt && walkTo == nil && clock > preenUntil {
                takeOff()
                plan(arriving: false)
                return
            }
            if pointerNear < 260 && pointerSpeed > 60 && walkTo == nil && clock > preenUntil && clock - lastTurnToPointer > 1.2 {
                lastTurnToPointer = clock
                facing = m.x > p.x ? 1 : -1
                headTarget = m.y > p.y + 30 * k ? -0.25 : 0.15
                headBack = false
                holdUntil = clock + 0.8
            }
            if clock > nextIdea && walkTo == nil && clock > preenUntil && squawks == 0 { haveAnIdea(perch) }
        }

        if let to = walkTo {
            let step = min(abs(to - p.x), walkSpeed * dt)
            if step < 0.5 {
                walkTo = nil
            } else {
                let dir: CGFloat = to > p.x ? 1 : -1
                facing = dir
                p.x += dir * step
                stride += Double(step) / (8 * Double(k))
                headBack = false
                turnedUntil = 0
            }
        }
        p.y = perch.y(at: p.x) - (bent?.kind == perch.kind ? depth : 0)
        if bent?.kind == perch.kind { bent?.at = CGPoint(x: p.x, y: perch.y(at: p.x)) }
        live(dt: dt)
    }

    /// The small life of a standing gull: blinks, quick glances held for a
    /// moment, calls with the head thrown up, preening in bursts with the
    /// bill deep in the back feathers.
    private func live(dt: CGFloat) {
        if clock > nextBlink {
            blinkUntil = clock + 0.13
            nextBlink = clock + .random(in: 1.5...5)
        }
        if squawks > 0 {
            if clock > squawkAt {
                // Each call: the head thrown up and the bill wide open.
                squawks -= 1
                headBack = false
                headTarget = -0.95
                billOpenUntil = clock + 0.28
                squawkAt = clock + 0.5
                holdUntil = clock + 0.5
            } else if clock > billOpenUntil {
                headTarget = -0.55
            }
        } else if clock < preenUntil {
            // Preening: the head turned back over the wing, nibbling in
            // quick bursts, resting between them.
            headBack = true
            ruffledUntil = max(ruffledUntil, clock + 0.3)
            if clock > nextNibble {
                nibbleUntil = clock + .random(in: 0.35...0.9)
                nextNibble = nibbleUntil + .random(in: 0.25...0.7)
                headTarget = .random(in: 0.75...1.05)
            }
        } else if walkTo == nil && clock > holdUntil && clock > nextGlance {
            // A glance: the head turns quickly and holds still.
            headBack = Double.random(in: 0..<1) < 0.12
            headTarget = .random(in: -0.25...0.3)
            nextGlance = clock + .random(in: 0.4...2.4)
            if Double.random(in: 0..<1) < 0.08 { facing = -facing }
        }
        if headBack && clock >= preenUntil && clock > holdUntil && clock > nextGlance - 0.2 { headBack = false }
        let ease = min(1, dt * (clock < nibbleUntil ? 30 : 16))
        headAngle += (headTarget - headAngle) * ease
    }

    /// What a gull does while it stands about.
    private func haveAnIdea(_ perch: Perch) {
        nextIdea = clock + .random(in: 1.6...4.2)
        switch Double.random(in: 0..<1) {
        case ..<0.16:
            // A long look up, down or back.
            headBack = Double.random(in: 0..<1) < 0.35
            headTarget = [-0.4, 0.5, 0.05].randomElement()!
            holdUntil = clock + .random(in: 0.8...2)
        case ..<0.36:
            preenUntil = clock + .random(in: 2.2...5)
            nextNibble = clock + 0.25
            nextIdea = preenUntil + 0.8
        case ..<0.44:
            // A shake: the feathers fluffed and shaken back into place.
            shakeUntil = clock + 0.45
            ruffledUntil = clock + 0.9
        case ..<0.52:
            squawks = Int.random(in: 1...3)
            squawkAt = clock
        case ..<0.78:
            let dx = CGFloat.random(in: 20...90) * (Bool.random() ? 1 : -1)
            if let x = perch.spot(near: p.x + dx), abs(x - p.x) > 8 {
                walkTo = x
                walkSpeed = .random(in: 30...48)
            }
        case ..<0.9:
            // Turns towards you for a while.
            turnedUntil = clock + .random(in: 3...8)
            headBack = false
        default:
            facing = -facing
            turnedUntil = 0
        }
    }

    // MARK: Following

    private func followFlying() {
        let m = NSEvent.mouseLocation
        let f = screen.frame.insetBy(dx: 30, dy: 30)
        let side: CGFloat = p.x < m.x ? -1 : 1
        let near = hypot(m.x - p.x, m.y - p.y)
        let still = clock - pointerStillSince
        landing = nil
        if near < 50 {
            // The pointer is on it: it holds still to be caught.
            route = [p]
            return
        }
        // Resting nearby: it settles on something close to the pointer.
        if still > 1.6, let spot = followSpot(near: m, side: side) {
            route = []
            landing = spot
            return
        }
        var target = CGPoint(x: m.x + side * 80, y: m.y + 36)
        if still > 1.6 {
            // Nothing to sit on: it circles the pointer.
            let a = clock * 0.9
            target = CGPoint(x: m.x + CGFloat(cos(a)) * 90, y: m.y + 50 + CGFloat(sin(a)) * 36)
        }
        target.x = min(max(target.x, f.minX), f.maxX)
        target.y = min(max(target.y, f.minY), f.maxY)
        route = [target]
    }

    private func followSpot(near m: CGPoint, side: CGFloat) -> (perch: Perch, x: CGFloat)? {
        var best: (perch: Perch, x: CGFloat, d: CGFloat)?
        for perch in perches {
            guard let x = perch.spot(near: m.x + side * 50) else { continue }
            let d = hypot(x - m.x, perch.y(at: x) - m.y)
            if d < 180, d < (best?.d ?? .greatestFiniteMagnitude) { best = (perch, x, d) }
        }
        return best.map { ($0.perch, $0.x) }
    }

    private func followStanding(_ perch: Perch) {
        let m = NSEvent.mouseLocation
        let y = perch.y(at: p.x)
        // The pointer went off elsewhere: it flies after it.
        if abs(m.y - y) > 300 || m.x < perch.minX - 140 || m.x > perch.maxX + 140 {
            takeOff()
            return
        }
        let side: CGFloat = p.x < m.x ? -1 : 1
        let near = hypot(m.x - p.x, m.y - (p.y + 15 * k))
        if near < 50 {
            walkTo = nil
            if clock - lastTurnToPointer > 0.8 { facing = m.x > p.x ? 1 : -1; lastTurnToPointer = clock }
            return
        }
        if let x = perch.spot(near: m.x + side * 46), abs(x - p.x) > 14 {
            if abs(x - p.x) > 320 {
                takeOff()
                return
            }
            walkTo = x
            walkSpeed = abs(x - p.x) > 120 ? 95 : 55
        } else if walkTo == nil {
            if clock - lastTurnToPointer > 0.8 { facing = m.x > p.x ? 1 : -1; lastTurnToPointer = clock }
            headBack = false
        }
    }

    private func clicked(_ count: Int) {
        guard count == 2 else {
            if case .standing = mode, count == 1 { squawks = 1; squawkAt = clock }
            return
        }
        toggleFollowing()
    }

    func toggleFollowing() {
        following.toggle()
        if following {
            squawks = 2
            squawkAt = clock
            if case .standing = mode { leaveAt = .greatestFiniteMagnitude }
        } else {
            squawks = 1
            squawkAt = clock
            if case .standing = mode {
                leaveAt = clock + 1.2
            } else {
                landing = nil
                route = [exitPoint()]
            }
        }
    }

    // MARK: The perch under its weight

    /// The rope or wire sags under the gull and swings when it lands or
    /// leaves: a damped spring with the gull's weight on it.
    private func swingPerch(dt: CGFloat) {
        guard let b = bent else { return }
        let loaded: Bool = {
            if case .standing = mode, let perch, perch.kind == b.kind { return true }
            return false
        }()
        let weight: CGFloat = loaded ? 6 : 0
        let steps = 4
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            depthSpeed += (-90 * (depth - weight) - 8 * depthSpeed) * h
            depth += depthSpeed * h
        }
        depth = max(-12, min(20, depth))
        if !loaded && abs(depth) < 0.08 && abs(depthSpeed) < 1 {
            world.bend(b.kind, at: b.at, depth: 0)
            bent = nil
            depth = 0
            depthSpeed = 0
            return
        }
        world.bend(b.kind, at: b.at, depth: depth)
    }

    // MARK: Drawing

    /// Gliding high up it is seen from below, white against the sky;
    /// beating its wings lower down, from the side and a little above.
    /// It changes a step at a time, as if it banked.
    private func chooseView(legs: Bool) {
        let f = screen.frame
        let high = (p.y - f.minY) / f.height
        let want: GullPictures.View
        if legs { want = .above }
        else if gliding { want = high > 0.55 ? .below : .level }
        else { want = high > 0.75 ? .level : .above }
        guard want != view, clock - viewChanged > 0.35 else { return }
        viewChanged = clock
        view = GullPictures.View(rawValue: view.rawValue + (want.rawValue > view.rawValue ? 1 : -1)) ?? want
    }

    private func draw() {
        let origin = window.frame.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var flight: GullPictures.Picture?
        var pitch: CGFloat = 0
        var at = p
        switch mode {
        case .standing where clock < touchdownUntil:
            // Just down, the wings still raised.
            flight = pictures.flapLegs[0]
            at.y += GullPictures.lift
            pitch = 0.15
        case .standing, .rising:
            break
        case .flying:
            let legs = landing != nil && route.isEmpty && hypot(p.x - landing!.x, p.y - landing!.perch.y(at: landing!.x)) < 140
            chooseView(legs: legs)
            if gliding {
                flight = legs ? pictures.glideLegs : pictures.glide[view]!
            } else {
                let i = Int(wingPhase * Double(GullPictures.phases)) % GullPictures.phases
                flight = legs ? pictures.flapLegs[i] : pictures.flap[view]![i]
                // The body rises on each downstroke and sinks on the upstroke.
                at.y += CGFloat(sin(2 * .pi * wingPhase)) * 1.6 * k
            }
            pitch = max(-0.35, min(0.35, atan2(v.dy, max(abs(v.dx), 90)) * 0.6))
            if legs { pitch = 0.3 }
        }
        bird.isHidden = flight == nil
        stander.isHidden = flight != nil
        if let flight {
            place(bird, flight, at: CGPoint(x: at.x - origin.x, y: at.y - origin.y))
            bird.transform = CATransform3DScale(CATransform3DMakeRotation(pitch * facing, 0, 0, 1), facing, 1, 1)
            return
        }
        drawStanding(at: CGPoint(x: p.x - origin.x, y: p.y - origin.y))
    }

    /// The standing bird in its parts: it breathes, crouches, shakes, steps
    /// with each leg in turn, and its head turns about the base of the neck.
    private func drawStanding(at feet: CGPoint) {
        let preening = clock < preenUntil
        let turn: GullPictures.Turn = clock < turnedUntil && walkTo == nil && !preening && !headBack ? .turned : .profile
        let j = GullPictures.joints(turn)
        let ruffled = clock < ruffledUntil
        // Unscaled, y down: how far the body is lowered.
        var dy: CGFloat = clock < crouchUntil || { if case .rising = mode { return true } else { return false } }() ? 2.4 : 0
        var nearSwing: CGFloat = turn == .turned ? 0.12 : 0, farSwing: CGFloat = turn == .turned ? -0.1 : 0
        var nearLift: CGFloat = 1, farLift: CGFloat = 1
        if walkTo != nil {
            let a = CGFloat(stride * 2 * .pi)
            nearSwing += 0.36 * sin(a)
            farSwing -= 0.36 * sin(a)
            // The leg swinging forward is the one off the rope, bent.
            if cos(a) > 0 { nearLift = 1 - 0.14 * cos(a) } else { farLift = 1 + 0.14 * cos(a) }
            dy -= 0.8 * abs(sin(a))
        }
        let crouch: CGFloat = dy > 1 ? (10.2 - dy) / 10.2 : 1
        let breath = 1 + 0.012 * CGFloat(sin(2 * .pi * 0.42 * clock))
        let shake: CGFloat = clock < shakeUntil ? 0.06 * CGFloat(sin(2 * .pi * 11 * clock)) : 0

        stander.position = feet
        stander.transform = CATransform3DMakeScale(facing, 1, 1)
        func local(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * k, y: -q.y * k) }

        place(body, pictures.body[turn]![ruffled]!, at: local(CGPoint(x: 0, y: dy)))
        body.transform = CATransform3DRotate(CATransform3DMakeScale(1, breath, 1), shake, 0, 0, 1)

        for (leg, picture, hip, swing, lift) in [(farLeg, pictures.farLeg, j.farHip, farSwing, farLift),
                                                 (nearLeg, pictures.nearLeg, j.nearHip, nearSwing, nearLift)] {
            place(leg, picture, at: local(CGPoint(x: hip.x, y: hip.y + dy)))
            leg.transform = CATransform3DRotate(CATransform3DMakeScale(1, min(lift, crouch), 1), swing, 0, 0, 1)
        }

        // Preening, the head goes back over the wing.
        let neck = preening && headBack ? CGPoint(x: -1.2, y: -26.2) : j.neck
        let nibble: CGFloat = clock < nibbleUntil ? 0.13 * CGFloat(sin(2 * .pi * 7.5 * clock)) : 0
        let bill: GullPictures.Bill = clock < billOpenUntil ? .open : (clock < blinkUntil ? .blink : .closed)
        place(head, pictures.head[turn]![bill]!, at: local(CGPoint(x: neck.x, y: neck.y * breath + dy)))
        let flip: CGFloat = headBack ? -1 : 1
        head.transform = CATransform3DRotate(CATransform3DMakeScale(flip, 1, 1), -(headAngle + nibble) * flip + shake, 0, 0, 1)
    }

    /// Shows `picture` on `layer` with its anchor at `point`.
    private func place(_ layer: CALayer, _ picture: GullPictures.Picture, at point: CGPoint) {
        let r = picture.rect
        if layer.contents as AnyObject? !== picture.image as AnyObject? { layer.contents = picture.image }
        layer.bounds = CGRect(origin: .zero, size: r.size)
        layer.anchorPoint = CGPoint(x: -r.minX / r.width, y: r.maxY / r.height)
        layer.position = point
    }
}

/// A clear window over the whole screen for the gull. It lets every click
/// through except right on the bird.
@MainActor
final class GullWindow: NSPanel {
    let gullView = GullView()

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        contentView = gullView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func catchMouse(_ catching: Bool) {
        if ignoresMouseEvents == catching { ignoresMouseEvents = !catching }
    }
}

@MainActor
final class GullView: NSView {
    var onClick: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount)
    }
}
