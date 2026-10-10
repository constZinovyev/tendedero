import AppKit
import QuartzCore

// MARK: - Pictures

/// The seagull, an adult herring gull facing right, drawn once per display
/// scale: white with a soft light from above and the belly in shade, a pale
/// gray back, black wingtips with white spots, a yellow bill with its red
/// spot. In flight it is seen from three heights, from the side and above
/// down to from below, where it shows its white underside; standing, in
/// profile or turned towards you. A visit only swaps these pictures and
/// moves one layer.
@MainActor
final class GullPictures {
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
    static let phases = 10

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

    let flap: [View: [Picture]]
    let flapLegs: [Picture]
    let glide: [View: Picture]
    let glideLegs: Picture
    let stand: [Pose: Picture]
    /// Standing turned three-quarters towards you.
    let turned: [Pose: Picture]
    let walk: [Picture]

    enum Pose: CaseIterable {
        case idle, blink, lookUp, lookDown, lookBack, squawk, preenA, preenB, crouch
        static let turnable: [Pose] = [.idle, .blink, .lookUp, .lookDown, .squawk]
    }

    private static var cache: [CGFloat: GullPictures] = [:]

    static func at(scale: CGFloat) -> GullPictures {
        if let p = cache[scale] { return p }
        let p = GullPictures(scale: scale)
        cache[scale] = p
        return p
    }

    /// The pictures take a few megabytes; between visits they are let go.
    static func forget() { cache = [:] }

    private init(scale: CGFloat) {
        let k = Self.size
        let flightRect = CGRect(x: -48, y: -54, width: 86, height: 106).scaled(k)
        let standRect = CGRect(x: -34, y: -45, width: 63, height: 50).scaled(k)
        func draw(_ rect: CGRect, _ body: @escaping (CGContext) -> Void) -> Picture {
            Picture(image: Sprite.draw(rect, scale: scale) { ctx in
                // One soft shadow under the whole bird.
                ctx.setShadow(offset: CGSize(width: 0, height: -1.4 * scale), blur: 3 * scale,
                              color: Sprite.rgba(0, 0, 0, 0.28))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.scaleBy(x: k, y: k)
                body(ctx)
                ctx.endTransparencyLayer()
            }, rect: Sprite.aligned(rect, scale: scale))
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
        var stand: [Pose: Picture] = [:], turned: [Pose: Picture] = [:]
        for pose in Pose.allCases { stand[pose] = draw(standRect) { Self.standing($0, Self.look(pose)) } }
        for pose in Pose.turnable {
            var look = Self.look(pose)
            look.turn = 1
            turned[pose] = draw(standRect) { Self.standing($0, look) }
        }
        self.stand = stand
        self.turned = turned
        walk = (0..<4).map { i in
            draw(standRect) { ctx in
                let a = Double(i) / 4 * 2 * .pi
                var look = Look()
                look.feet = (CGFloat(sin(a)) * 3.4, max(0, CGFloat(cos(a))) * 2.4,
                             -CGFloat(sin(a)) * 3.4, max(0, -CGFloat(cos(a))) * 2.4)
                look.bob = -abs(CGFloat(sin(a))) * 0.8
                look.head.x += CGFloat(sin(a)) * 0.7
                Self.standing(ctx, look)
            }
        }
    }

    // MARK: Colors

    private static let white = Sprite.rgba(251, 251, 249, 1)
    private static let shade = Sprite.rgba(158, 170, 186, 1)
    private static let rim = Sprite.rgba(104, 116, 132, 1)
    private static let mantleDark = Sprite.rgba(146, 158, 172, 1)
    private static let mantleLight = Sprite.rgba(180, 191, 202, 1)
    private static let underwing = Sprite.rgba(238, 241, 245, 1)
    private static let underwingShade = Sprite.rgba(196, 204, 215, 1)
    private static let black = Sprite.rgba(26, 26, 30, 1)
    private static let blackSheen = Sprite.rgba(70, 72, 80, 1)
    private static let billBase = Sprite.rgba(246, 204, 64, 1)
    private static let billTip = Sprite.rgba(232, 172, 34, 1)
    private static let gonys = Sprite.rgba(214, 52, 34, 1)
    private static let leg = Sprite.rgba(228, 164, 152, 1)
    private static let legShade = Sprite.rgba(192, 124, 116, 1)

    // MARK: Shared parts

    /// White plumage over the union of `parts`: lit from above, the lower
    /// side in a cool shade, and a soft darker rim so it reads on a light
    /// desktop. `shadeFrom`/`shadeTo` run from lit to shaded, y down.
    private static func plumage(_ ctx: CGContext, _ parts: [CGPath], shadeFrom: CGFloat, shadeTo: CGFloat,
                                depth: CGFloat = 0.6) {
        var union = parts[0]
        for p in parts.dropFirst() { union = union.union(p) }
        Sprite.fill(ctx, union, white)
        Sprite.clipped(ctx, union) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: shadeFrom), to: CGPoint(x: 0, y: shadeTo),
                          [(0, Sprite.rgba(255, 255, 255, 0)), (0.55, Self.alpha(shade, depth * 0.45)), (1, Self.alpha(shade, depth))])
            Sprite.stroke(ctx, union, alpha(rim, 0.14), width: 3.2)
            Sprite.stroke(ctx, union, alpha(rim, 0.3), width: 1.2)
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

    private static func headTransform(at c: CGPoint, angle: CGFloat, back: Bool, turn: CGFloat, size: CGFloat) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: c.x, y: c.y)
        if back { t = t.scaledBy(x: -1, y: 1) }
        return t.rotated(by: angle).scaledBy(x: size * (1 - 0.18 * turn), y: size)
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
        // The gape and the nostril.
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
            Sprite.stroke(ctx, lid, Sprite.rgba(90, 96, 104, 0.85), width: 0.4)
        } else {
            Sprite.fill(ctx, Sprite.ellipse(eye.x, eye.y, 0.95, 0.9), Sprite.rgba(238, 224, 160, 1))
            Sprite.stroke(ctx, Sprite.ellipse(eye.x, eye.y, 1.0, 0.95), Sprite.rgba(222, 112, 62, 0.9), width: 0.3)
            Sprite.fill(ctx, Sprite.ellipse(eye.x + 0.08, eye.y, 0.42, 0.42), Sprite.rgba(18, 18, 20, 1))
            Sprite.fill(ctx, Sprite.ellipse(eye.x + 0.25, eye.y - 0.25, 0.17, 0.17), Sprite.rgba(255, 255, 255, 0.95))
        }
        ctx.restoreGState()
    }

    // MARK: Standing

    struct Look {
        var head = CGPoint(x: 9.8, y: -30.4)
        var angle: CGFloat = 0
        var open: CGFloat = 0
        /// Turned to face backwards.
        var back = false
        var blink = false
        /// Drawn over the folded wing, when it reaches back into it.
        var overWing = false
        var bob: CGFloat = 0
        var crouch: CGFloat = 0
        /// Turned towards us: 0 in profile, 1 three-quarters.
        var turn: CGFloat = 0
        /// Each foot: moved forward, lifted.
        var feet: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    }

    private static func look(_ pose: Pose) -> Look {
        var l = Look()
        switch pose {
        case .idle: break
        case .blink: l.blink = true
        case .lookUp: l.head = CGPoint(x: 10.2, y: -31); l.angle = -0.35
        case .lookDown: l.head = CGPoint(x: 11.2, y: -29); l.angle = 0.45
        case .lookBack: l.back = true; l.head = CGPoint(x: 8.2, y: -30.6); l.angle = -0.08
        case .squawk: l.head = CGPoint(x: 10.6, y: -31.4); l.angle = -0.8; l.open = 0.42
        case .preenA: l.back = true; l.overWing = true; l.head = CGPoint(x: -1.8, y: -27.4); l.angle = 0.75
        case .preenB: l.back = true; l.overWing = true; l.head = CGPoint(x: -3.6, y: -26.6); l.angle = 0.95; l.blink = true
        case .crouch: l.crouch = 2.6; l.head = CGPoint(x: 11, y: -28.8); l.angle = 0.1
        }
        return l
    }

    /// A standing gull, feet at (0, 0).
    private static func standing(_ ctx: CGContext, _ l: Look) {
        let dy = l.bob + l.crouch
        let turn = l.turn
        // Legs: the far one a little darker; turned towards us they stand apart.
        let legs: [(hip: CGPoint, foot: CGFloat, lift: CGFloat, far: Bool)] = [
            (CGPoint(x: 2.4 - turn * 0.6, y: -10.6 + dy), 2.6 + l.feet.2 + turn * 1.2, l.feet.3, true),
            (CGPoint(x: -1.6 - turn * 0.6, y: -10.2 + dy), -2.2 + l.feet.0 - turn * 1.6, l.feet.1, false),
        ]
        for limb in legs {
            let end = CGPoint(x: limb.foot, y: -limb.lift)
            let knee = CGPoint(x: (limb.hip.x + end.x) / 2 + l.crouch * 0.9, y: (limb.hip.y + end.y) / 2)
            let p = CGMutablePath()
            p.move(to: limb.hip)
            p.addLine(to: knee)
            p.addLine(to: end)
            Sprite.stroke(ctx, p, limb.far ? legShade : leg, width: 1.45)
            // A webbed foot, shorter when it points towards us.
            let toe = 4.4 * (1 - turn * 0.45)
            let web = CGMutablePath()
            web.move(to: CGPoint(x: end.x - 1.4, y: end.y - 0.2))
            web.addLine(to: CGPoint(x: end.x + toe, y: end.y - 0.3))
            web.addLine(to: CGPoint(x: end.x + toe * 0.8, y: end.y + 0.7))
            web.addLine(to: CGPoint(x: end.x - 0.6, y: end.y + 0.6))
            web.closeSubpath()
            Sprite.fill(ctx, web, limb.far ? legShade : leg)
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dy)
        // Turned towards us the body is shorter and the breast fuller.
        let squeeze = CGAffineTransform(scaleX: 1 - 0.26 * turn, y: 1)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 6, y: -31), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 2, y: -26), control: CGPoint(x: 3.2, y: -29.5), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: -12, y: -22), control: CGPoint(x: -4, y: -23.8), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: -24.5, y: -16.6), control: CGPoint(x: -19, y: -19.6), transform: squeeze)
        body.addLine(to: CGPoint(x: -25, y: -14.6), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: -11.5, y: -11), control: CGPoint(x: -18, y: -12.2), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 4.5, y: -10.2), control: CGPoint(x: -3, y: -8.6), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 12, y: -19.5), control: CGPoint(x: 12, y: -12.2), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 12.5, y: -28), control: CGPoint(x: 12.8, y: -24), transform: squeeze)
        body.addQuadCurve(to: CGPoint(x: 6, y: -31), control: CGPoint(x: 10, y: -32.5), transform: squeeze)
        body.closeSubpath()
        var parts: [CGPath] = [body]
        if turn > 0 { parts.append(Sprite.ellipse(5.5, -18.5, 6.4 * turn + 0.1, 8.4)) }
        let headCenter = CGPoint(x: l.head.x - turn * 1.8, y: l.head.y - dy * 0.3)
        let t = headTransform(at: headCenter, angle: l.angle, back: l.back, turn: turn, size: 1)
        let head = headShape(t)
        if !l.overWing { parts.append(head) }
        plumage(ctx, parts, shadeFrom: -24, shadeTo: -9)

        // The folded wing over the back, its black tips past the tail.
        ctx.saveGState()
        ctx.concatenate(squeeze)
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
            Sprite.fill(ctx, Sprite.ellipse(-3, -14.2, 13, 2.2), Sprite.rgba(120, 132, 150, 0.16))
        }
        Sprite.clipped(ctx, wing) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: -26), to: CGPoint(x: 0, y: -14),
                          [(0, mantleDark), (0.6, mantleLight), (1, Sprite.rgba(196, 205, 214, 1))])
            // Rows of feathers, just hinted.
            for (a, b, c, alpha) in [(CGPoint(x: 5, y: -21.5), CGPoint(x: -12, y: -21), CGPoint(x: -3, y: -24), 0.35),
                                     (CGPoint(x: 4, y: -19.6), CGPoint(x: -13, y: -17.8), CGPoint(x: -4, y: -20.6), 0.3),
                                     (CGPoint(x: -4, y: -23.6), CGPoint(x: -16, y: -19.6), CGPoint(x: -11, y: -23), 0.25)] {
                let row = CGMutablePath()
                row.move(to: a)
                row.addQuadCurve(to: b, control: c)
                Sprite.stroke(ctx, row, Sprite.rgba(214, 222, 230, CGFloat(alpha)), width: 0.6)
            }
            Sprite.stroke(ctx, wing, Sprite.rgba(110, 122, 138, 0.35), width: 1.0)
        }
        // The white edges of the tertials.
        let tertials = CGMutablePath()
        tertials.move(to: CGPoint(x: -12.6, y: -15.2))
        tertials.addQuadCurve(to: CGPoint(x: 4.2, y: -17.6), control: CGPoint(x: -3.5, y: -14.2))
        Sprite.stroke(ctx, tertials, Sprite.rgba(252, 252, 250, 0.95), width: 1.3)
        ctx.restoreGState()

        if l.overWing { plumage(ctx, [head], shadeFrom: headCenter.y - 3, shadeTo: headCenter.y + 5, depth: 0.4) }
        face(ctx, t, open: l.open, blink: l.blink, reach: 1 - 0.38 * turn)
        ctx.restoreGState()
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
        let from: CGFloat = cam.rise < 0 ? -8 : -5, depth: CGFloat = cam.rise < 0 ? 0.75 : 0.6
        plumage(ctx, [body], shadeFrom: from, shadeTo: 5.5, depth: depth)
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
        let below = mix(underwingShade, underwing, near ? 0.75 : 0.35)
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
            let dark = mix(black, blackSheen, under * 0.5)
            Sprite.fill(ctx, feather, dark)
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
                          ? [(0, Sprite.rgba(255, 255, 255, 0.18)), (0.6, Sprite.rgba(255, 255, 255, 0)), (1, Sprite.rgba(0, 0, 0, 0.06))]
                          : [(0, Sprite.rgba(255, 255, 255, 0.1)), (0.5, Sprite.rgba(255, 255, 255, 0.25)), (1, Sprite.rgba(120, 130, 145, 0.15))])
            // The white trailing edge on top, soft gray below.
            let edge = smooth(trail.map { point($0.0, $0.1 - 0.012) }, closed: false)
            Sprite.stroke(ctx, edge, under < 0.5 ? Sprite.rgba(252, 252, 250, 0.95) : Sprite.rgba(170, 180, 192, 0.45),
                          width: under < 0.5 ? 2.4 : 1.6)
            Sprite.stroke(ctx, plate, alpha(rim, 0.22), width: 1.4)
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

    /// A gull comes now, unless one is here already.
    func arrive() {
        if let visit, visit.isLeaving { visit.end() }
        guard visit == nil, let screen = GarlandController.lineScreen else { return }
        let v = GullVisit(screen: screen, world: self)
        visit = v
        v.onEnd = { [weak self, weak v] in
            if self?.visit === v { self?.visit = nil }
        }
        v.start()
    }

    private var pressTimer: Timer?

    /// ⌥⌘G: once calls a gull, or sends away the one that is here; twice
    /// quickly, it follows the pointer, or stops following.
    func shortcutPressed() {
        if let t = pressTimer {
            t.invalidate()
            pressTimer = nil
            if visit == nil { arrive() }
            visit?.toggleFollowing()
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
    private let bird = CALayer()
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
    private var pose = GullPictures.Pose.idle
    private var poseUntil: CFTimeInterval = 0
    private var preenUntil: CFTimeInterval = 0
    private var squawks = 0
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

    init(screen: NSScreen, world: Seagulls) {
        self.screen = screen
        self.world = world
        window = GullWindow(frame: screen.frame)
        pictures = GullPictures.at(scale: screen.backingScaleFactor)
        super.init()
        window.gullView.onClick = { [weak self] count in self?.clicked(count) }
        bird.contentsScale = screen.backingScaleFactor
        window.gullView.layer?.addSublayer(bird)
    }

    func start() {
        let f = screen.frame
        let fromLeft = Bool.random()
        facing = fromLeft ? 1 : -1
        p = CGPoint(x: fromLeft ? f.minX - 60 : f.maxX + 60, y: f.minY + f.height * .random(in: 0.55...0.85))
        v = CGVector(dx: facing * 260, dy: -20)
        clock = CACurrentMediaTime()
        plan(arriving: true)
        if let line = world.lineWindow, line.isVisible {
            window.level = line.level
            window.orderFrontRegardless()
            window.order(.above, relativeTo: line.windowNumber)
        } else {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
            window.orderFrontRegardless()
        }
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
        draw()
        // Standing still it only blinks and looks about: a calmer pace will do.
        var calm = false
        if case .standing = mode, walkTo == nil, bent == nil || abs(depthSpeed) < 2 { calm = !following }
        if calm != calmPace {
            calmPace = calm
            link.preferredFrameRateRange = calm ? CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
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
        if following { followFlying() }
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
        pose = .crouch
        poseUntil = clock + 0.25
        nextIdea = clock + .random(in: 0.8...2)
        leaveAt = clock + .random(in: 12...35)
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
        pose = .crouch
        depthSpeed += 48
        world.jolt(perch.kind, at: p, strength: 1.5)
        p.y += GullPictures.lift
        v = CGVector(dx: facing * 170, dy: 230)
        wingPhase = 0.1
        self.perch = nil
        walkTo = nil
        world.air(at: p, velocity: CGVector(dx: facing * 600, dy: -380))
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
            // A sudden sweep close by frightens it off.
            if pointerNear < 90 && pointerSpeed > 900 {
                takeOff(away: m)
                plan(arriving: false)
                return
            }
            if clock > leaveAt && walkTo == nil {
                takeOff()
                plan(arriving: false)
                return
            }
            if pointerNear < 260 && pointerSpeed > 60 && walkTo == nil && clock - lastTurnToPointer > 1.2 {
                lastTurnToPointer = clock
                facing = m.x > p.x ? 1 : -1
            }
            if clock > nextIdea && walkTo == nil { haveAnIdea(perch) }
        }

        if let to = walkTo {
            let step = min(abs(to - p.x), walkSpeed * dt)
            if step < 0.5 {
                walkTo = nil
                pose = .idle
            } else {
                let dir: CGFloat = to > p.x ? 1 : -1
                facing = dir
                p.x += dir * step
                stride += Double(step) / 7
            }
        }
        p.y = perch.y(at: p.x) - (bent?.kind == perch.kind ? depth : 0)
        if bent?.kind == perch.kind { bent?.at = CGPoint(x: p.x, y: perch.y(at: p.x)) }

        if clock < preenUntil, walkTo == nil {
            pose = Int(clock * 3.2) % 2 == 0 ? .preenA : .preenB
        } else if squawks > 0, clock > poseUntil {
            pose = pose == .squawk ? .lookUp : .squawk
            poseUntil = clock + (pose == .squawk ? 0.32 : 0.2)
            if pose == .squawk { squawks -= 1 }
        } else if clock > poseUntil, pose != .idle, walkTo == nil {
            pose = .idle
        }
    }

    /// What a gull does while it stands about.
    private func haveAnIdea(_ perch: Perch) {
        nextIdea = clock + .random(in: 1.4...3.8)
        let r = Double.random(in: 0..<1)
        switch r {
        case ..<0.18:
            pose = .blink; poseUntil = clock + 0.14
        case ..<0.34:
            pose = [.lookUp, .lookDown, .lookBack].randomElement()!
            poseUntil = clock + .random(in: 0.8...2)
        case ..<0.46:
            preenUntil = clock + .random(in: 1.6...3.2)
            nextIdea = preenUntil + 0.6
        case ..<0.55:
            squawks = Int.random(in: 1...3)
            poseUntil = clock
        case ..<0.82:
            let dx = CGFloat.random(in: 20...90) * (Bool.random() ? 1 : -1)
            if let x = perch.spot(near: p.x + dx), abs(x - p.x) > 8 {
                turnedUntil = 0
                walkTo = x
                walkSpeed = .random(in: 32...52)
            }
        case ..<0.92:
            // Turns towards you for a while.
            turnedUntil = clock + .random(in: 3...8)
            pose = .idle
            nextIdea = clock + .random(in: 1...2)
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
            if clock > nextIdea { nextIdea = clock + .random(in: 2...4); pose = [.blink, .lookUp, .lookDown].randomElement()!; poseUntil = clock + 0.6 }
        }
    }

    private func clicked(_ count: Int) {
        guard count == 2 else {
            if case .standing = mode, count == 1 { squawks = 1; poseUntil = clock }
            return
        }
        toggleFollowing()
    }

    func toggleFollowing() {
        following.toggle()
        if following {
            squawks = 2
            poseUntil = clock
            if case .standing = mode { leaveAt = .greatestFiniteMagnitude }
        } else {
            squawks = 1
            poseUntil = clock
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
        let picture: GullPictures.Picture
        var pitch: CGFloat = 0
        switch mode {
        case .standing:
            if walkTo != nil {
                picture = pictures.walk[Int(stride) % 4]
            } else if clock < turnedUntil, let turned = pictures.turned[pose] {
                picture = turned
            } else {
                picture = pictures.stand[pose] ?? pictures.stand[.idle]!
            }
        case .rising:
            picture = pictures.stand[.crouch]!
        case .flying:
            let legs = landing != nil && route.isEmpty && hypot(p.x - landing!.x, p.y - landing!.perch.y(at: landing!.x)) < 140
            chooseView(legs: legs)
            if gliding {
                picture = legs ? pictures.glideLegs : pictures.glide[view]!
            } else {
                let i = Int(wingPhase * Double(GullPictures.phases)) % GullPictures.phases
                picture = legs ? pictures.flapLegs[i] : pictures.flap[view]![i]
            }
            pitch = max(-0.35, min(0.35, atan2(v.dy, max(abs(v.dx), 90)) * 0.6))
            if legs { pitch = 0.3 }
        }
        let origin = window.frame.origin
        let r = picture.rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bird.contents = picture.image
        bird.bounds = CGRect(origin: .zero, size: r.size)
        bird.anchorPoint = CGPoint(x: -r.minX / r.width, y: r.maxY / r.height)
        bird.position = CGPoint(x: p.x - origin.x, y: p.y - origin.y)
        bird.transform = CATransform3DScale(CATransform3DMakeRotation(pitch * facing, 0, 0, 1), facing, 1, 1)
        CATransaction.commit()
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
