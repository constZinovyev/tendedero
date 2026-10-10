import AppKit
import QuartzCore

// MARK: - Pictures

/// The seagull, a herring gull seen from the side and facing right, drawn
/// once per display scale: a dozen moments of a wingbeat, with legs tucked
/// and let down, a glide, and a few standing poses. A visit only swaps
/// these pictures and moves one layer.
@MainActor
final class GullPictures {
    struct Picture {
        let image: CGImage?
        /// Where it was drawn, around its anchor, in points, y down.
        let rect: CGRect
    }

    /// The bird's size: 1 is about 50 points from tail to bill.
    static let size: CGFloat = 0.8
    /// The body's middle in flight is this far above the feet.
    static let lift: CGFloat = 15 * size

    let flap: [Picture]
    let flapLegs: [Picture]
    let glide: Picture
    let glideLegs: Picture
    let stand: [Pose: Picture]
    let walk: [Picture]

    enum Pose: CaseIterable {
        case idle, blink, lookUp, lookDown, lookBack, squawk, preenA, preenB, crouch
    }

    private static var cache: [CGFloat: GullPictures] = [:]

    static func at(scale: CGFloat) -> GullPictures {
        if let p = cache[scale] { return p }
        let p = GullPictures(scale: scale)
        cache[scale] = p
        return p
    }

    private init(scale: CGFloat) {
        let k = Self.size
        let flightRect = CGRect(x: -46, y: -52, width: 80, height: 102).scaled(k)
        let standRect = CGRect(x: -33, y: -44, width: 63, height: 50).scaled(k)
        func draw(_ rect: CGRect, _ body: @escaping (CGContext) -> Void) -> Picture {
            Picture(image: Sprite.draw(rect, scale: scale) { ctx in
                // One soft shadow under the whole bird, so the white reads on
                // a light desktop.
                ctx.setShadow(offset: CGSize(width: 0, height: -1.2 * scale), blur: 2.6 * scale,
                              color: Sprite.rgba(0, 0, 0, 0.3))
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.scaleBy(x: k, y: k)
                body(ctx)
                ctx.endTransparencyLayer()
            }, rect: Sprite.aligned(rect, scale: scale))
        }
        let phases = 12
        flap = (0..<phases).map { i in draw(flightRect) { Self.flight($0, phase: Double(i) / Double(phases), legs: false) } }
        flapLegs = (0..<phases).map { i in draw(flightRect) { Self.flight($0, phase: Double(i) / Double(phases), legs: true) } }
        glide = draw(flightRect) { Self.flight($0, phase: nil, legs: false) }
        glideLegs = draw(flightRect) { Self.flight($0, phase: nil, legs: true) }
        var stand: [Pose: Picture] = [:]
        for pose in Pose.allCases { stand[pose] = draw(standRect) { Self.standing($0, Self.look(pose)) } }
        self.stand = stand
        walk = (0..<4).map { i in
            draw(standRect) { ctx in
                let a = Double(i) / 4 * 2 * .pi
                var look = Look()
                look.feet = (CGFloat(sin(a)) * 3.2, max(0, CGFloat(cos(a))) * 2.2,
                             -CGFloat(sin(a)) * 3.2, max(0, -CGFloat(cos(a))) * 2.2)
                look.bob = -abs(CGFloat(sin(a))) * 0.8
                look.head.x += CGFloat(sin(a)) * 0.6
                Self.standing(ctx, look)
            }
        }
    }

    // MARK: Colors

    private static let white = Sprite.rgba(252, 252, 250, 1)
    private static let underside = Sprite.rgba(214, 220, 226, 1)
    private static let edge = Sprite.rgba(74, 82, 92, 0.55)
    private static let mantle = Sprite.rgba(170, 182, 193, 1)
    private static let farMantle = Sprite.rgba(146, 158, 170, 1)
    private static let underwing = Sprite.rgba(240, 242, 245, 1)
    private static let farUnderwing = Sprite.rgba(214, 219, 224, 1)
    private static let tip = Sprite.rgba(28, 28, 32, 1)
    private static let beak = Sprite.rgba(246, 199, 52, 1)
    private static let beakEdge = Sprite.rgba(186, 136, 28, 0.9)
    private static let gonys = Sprite.rgba(214, 56, 38, 1)
    private static let leg = Sprite.rgba(232, 168, 156, 1)
    private static let eye = Sprite.rgba(24, 24, 26, 1)

    // MARK: Head

    /// Where the head is and how it is held, for a standing bird.
    struct Look {
        var head = CGPoint(x: 10, y: -29)
        var angle: CGFloat = 0
        var open: CGFloat = 0
        /// Turned to face backwards.
        var back = false
        var blink = false
        /// Drawn over the folded wing, when it reaches back into it.
        var overWing = false
        var bob: CGFloat = 0
        var crouch: CGFloat = 0
        /// Each foot: moved forward, lifted.
        var feet: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    }

    private static func look(_ pose: Pose) -> Look {
        var l = Look()
        switch pose {
        case .idle: break
        case .blink: l.blink = true
        case .lookUp: l.head = CGPoint(x: 10.5, y: -29.8); l.angle = -0.38
        case .lookDown: l.head = CGPoint(x: 11.5, y: -27.4); l.angle = 0.5
        case .lookBack: l.back = true; l.head = CGPoint(x: 8.5, y: -29.2); l.angle = -0.1
        case .squawk: l.head = CGPoint(x: 10.8, y: -30.2); l.angle = -0.75; l.open = 0.5
        case .preenA: l.back = true; l.overWing = true; l.head = CGPoint(x: -1.5, y: -26.5); l.angle = 0.75
        case .preenB: l.back = true; l.overWing = true; l.head = CGPoint(x: -3.5, y: -25.8); l.angle = 0.95; l.blink = true
        case .crouch: l.crouch = 2.6; l.head = CGPoint(x: 11, y: -27.6); l.angle = 0.1
        }
        return l
    }

    private static func headTransform(at c: CGPoint, angle: CGFloat, back: Bool, size r: CGFloat) -> CGAffineTransform {
        var t = CGAffineTransform(translationX: c.x, y: c.y)
        if back { t = t.scaledBy(x: -1, y: 1) }
        return t.rotated(by: angle).scaledBy(x: r / 5.2, y: r / 5.2)
    }

    private static func skull(_ t: CGAffineTransform) -> CGPath {
        var t = t
        return CGPath(ellipseIn: CGRect(x: -5.4, y: -5.1, width: 10.8, height: 10.2), transform: &t)
    }

    /// The bill and the eye, over a head already filled white.
    private static func face(_ ctx: CGContext, _ t: CGAffineTransform, open: CGFloat, blink: Bool) {
        ctx.saveGState()
        ctx.concatenate(t)
        // The lower mandible turns open about the gape.
        ctx.saveGState()
        ctx.translateBy(x: 3.8, y: 0.8)
        ctx.rotate(by: open)
        let lower = CGMutablePath()
        lower.move(to: CGPoint(x: -0.4, y: -0.2))
        lower.addLine(to: CGPoint(x: 6.7, y: -0.3))
        lower.addQuadCurve(to: CGPoint(x: 4.9, y: 1.4), control: CGPoint(x: 6.2, y: 1.3))
        lower.addQuadCurve(to: CGPoint(x: -0.2, y: 1.2), control: CGPoint(x: 2.2, y: 1.1))
        lower.closeSubpath()
        Sprite.fill(ctx, lower, beak)
        Sprite.stroke(ctx, lower, beakEdge, width: 0.35)
        Sprite.fill(ctx, Sprite.ellipse(5.0, 0.55, 0.85, 0.65), gonys)
        ctx.restoreGState()
        let upper = CGMutablePath()
        upper.move(to: CGPoint(x: 3.1, y: -1.6))
        upper.addQuadCurve(to: CGPoint(x: 11.0, y: -0.3), control: CGPoint(x: 7.6, y: -2.0))
        upper.addQuadCurve(to: CGPoint(x: 10.7, y: 1.2), control: CGPoint(x: 11.7, y: 0.5))
        upper.addQuadCurve(to: CGPoint(x: 10.0, y: 0.7), control: CGPoint(x: 10.4, y: 0.7))
        upper.addLine(to: CGPoint(x: 3.5, y: 0.9))
        upper.closeSubpath()
        Sprite.fill(ctx, upper, beak)
        Sprite.stroke(ctx, upper, beakEdge, width: 0.35)
        if blink {
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: 0.9, y: -1.3))
            lid.addQuadCurve(to: CGPoint(x: 3.0, y: -1.3), control: CGPoint(x: 1.95, y: -0.6))
            Sprite.stroke(ctx, lid, Sprite.rgba(60, 64, 70, 0.9), width: 0.55)
        } else {
            Sprite.fill(ctx, Sprite.ellipse(1.95, -1.45, 1.05, 1.05), Sprite.rgba(232, 214, 120, 1))
            Sprite.fill(ctx, Sprite.ellipse(2.05, -1.45, 0.62, 0.62), eye)
            Sprite.fill(ctx, Sprite.ellipse(2.25, -1.7, 0.22, 0.22), Sprite.rgba(255, 255, 255, 0.9))
        }
        ctx.restoreGState()
    }

    /// White parts drawn as one: every outline first, then every fill over
    /// them, so only the outer edge of the whole silhouette shows.
    private static func silhouette(_ ctx: CGContext, _ parts: [CGPath]) {
        for p in parts { Sprite.stroke(ctx, p, edge, width: 1.3) }
        for p in parts { Sprite.fill(ctx, p, white) }
    }

    // MARK: Standing

    /// A standing gull, feet at (0, 0).
    private static func standing(_ ctx: CGContext, _ l: Look) {
        let dy = l.bob + l.crouch
        // Legs, behind the body, with a knee that bends when crouching.
        for (hip, foot, lift) in [(CGPoint(x: -1.5, y: -10.5 + dy), -2.2 + l.feet.0, l.feet.1),
                                  (CGPoint(x: 2.6, y: -11 + dy), 2.8 + l.feet.2, l.feet.3)] {
            let end = CGPoint(x: foot, y: -lift)
            let knee = CGPoint(x: (hip.x + end.x) / 2 + l.crouch * 0.9, y: (hip.y + end.y) / 2)
            let p = CGMutablePath()
            p.move(to: hip)
            p.addLine(to: knee)
            p.addLine(to: end)
            Sprite.stroke(ctx, p, leg, width: 1.5)
            let toes = CGMutablePath()
            toes.move(to: CGPoint(x: end.x - 1.2, y: end.y))
            toes.addLine(to: CGPoint(x: end.x + 3.2, y: end.y + 0.2))
            Sprite.stroke(ctx, toes, leg, width: 1.3)
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dy)
        let body = Sprite.ellipse(-1, -17.5, 14, 8.2, rotation: -0.16)
        let breast = Sprite.ellipse(6.5, -22, 5.6, 7, rotation: 0.4)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: -11, y: -20))
        tail.addLine(to: CGPoint(x: -22.5, y: -17))
        tail.addLine(to: CGPoint(x: -22, y: -14))
        tail.addLine(to: CGPoint(x: -11, y: -12.5))
        tail.closeSubpath()
        let t = headTransform(at: CGPoint(x: l.head.x, y: l.head.y - dy * 0.3), angle: l.angle, back: l.back, size: 5.2)
        let head = skull(t)
        silhouette(ctx, l.overWing ? [tail, body, breast] : [tail, body, breast, head])
        // The belly a little in shade.
        Sprite.clipped(ctx, body) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: -18), to: CGPoint(x: 0, y: -9),
                          [(0, Sprite.rgba(255, 255, 255, 0)), (1, underside)])
        }
        // The folded wing over the back, its black tips past the tail.
        let primaries = CGMutablePath()
        primaries.move(to: CGPoint(x: -12, y: -21.5))
        primaries.addQuadCurve(to: CGPoint(x: -28, y: -16.4), control: CGPoint(x: -21, y: -20))
        primaries.addLine(to: CGPoint(x: -27.2, y: -14.8))
        primaries.addQuadCurve(to: CGPoint(x: -12, y: -15.2), control: CGPoint(x: -20, y: -14.6))
        primaries.closeSubpath()
        Sprite.fill(ctx, primaries, tip)
        Sprite.fill(ctx, Sprite.ellipse(-25.6, -15.9, 0.9, 0.7), Sprite.rgba(255, 255, 255, 0.95))
        Sprite.fill(ctx, Sprite.ellipse(-22.2, -16.6, 0.7, 0.55), Sprite.rgba(255, 255, 255, 0.85))
        let wing = CGMutablePath()
        wing.move(to: CGPoint(x: 6, y: -22.5))
        wing.addQuadCurve(to: CGPoint(x: -8, y: -25.8), control: CGPoint(x: 0, y: -26.8))
        wing.addQuadCurve(to: CGPoint(x: -17, y: -19.2), control: CGPoint(x: -14, y: -24.4))
        wing.addLine(to: CGPoint(x: -12, y: -14.4))
        wing.addQuadCurve(to: CGPoint(x: 5, y: -17.2), control: CGPoint(x: -3, y: -13.2))
        wing.closeSubpath()
        Sprite.fill(ctx, wing, mantle)
        Sprite.stroke(ctx, wing, Sprite.rgba(110, 122, 134, 0.5), width: 0.5)
        let tertials = CGMutablePath()
        tertials.move(to: CGPoint(x: -11.4, y: -14.9))
        tertials.addQuadCurve(to: CGPoint(x: 3.5, y: -17.1), control: CGPoint(x: -3, y: -13.9))
        Sprite.stroke(ctx, tertials, Sprite.rgba(255, 255, 255, 0.95), width: 1.1)
        let scapulars = CGMutablePath()
        scapulars.move(to: CGPoint(x: -15.6, y: -20))
        scapulars.addQuadCurve(to: CGPoint(x: -4, y: -19.4), control: CGPoint(x: -9, y: -21.6))
        Sprite.stroke(ctx, scapulars, Sprite.rgba(255, 255, 255, 0.7), width: 0.7)
        if l.overWing { silhouette(ctx, [head]) }
        face(ctx, t, open: l.open, blink: l.blink)
        ctx.restoreGState()
    }

    // MARK: Flying

    /// A flying gull, the middle of its body at (0, 0). `phase` runs through
    /// one wingbeat from wings high; nil is a glide.
    private static func flight(_ ctx: CGContext, phase: Double?, legs: Bool) {
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
            hand = -0.14
            fold = 0
        }
        wing(ctx, near: false, arm: arm, hand: hand, fold: fold)
        if legs {
            for (hip, foot) in [(CGPoint(x: -3.5, y: 3), CGPoint(x: -9, y: 11)),
                                (CGPoint(x: -1.5, y: 3.5), CGPoint(x: -6.4, y: 12))] {
                let p = CGMutablePath()
                p.move(to: hip)
                p.addLine(to: foot)
                p.addLine(to: CGPoint(x: foot.x + 2.2, y: foot.y + 1.4))
                Sprite.stroke(ctx, p, leg, width: 1.4)
            }
        }
        let body = Sprite.ellipse(0, 0, 13.6, 5.7, rotation: -0.04)
        let neck = Sprite.ellipse(8.5, -1.6, 5.2, 4.5, rotation: -0.3)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: -11, y: -2.8))
        tail.addLine(to: CGPoint(x: -21, y: -1.9))
        tail.addQuadCurve(to: CGPoint(x: -21, y: 1.9), control: CGPoint(x: -21.8, y: 0))
        tail.addLine(to: CGPoint(x: -11, y: 3.8))
        tail.closeSubpath()
        let t = headTransform(at: CGPoint(x: 13.2, y: -3.2), angle: 0.1, back: false, size: 4.8)
        silhouette(ctx, [tail, body, neck, skull(t)])
        Sprite.clipped(ctx, body) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: -1), to: CGPoint(x: 0, y: 6),
                          [(0, Sprite.rgba(255, 255, 255, 0)), (1, underside)])
        }
        face(ctx, t, open: 0, blink: false)
        wing(ctx, near: true, arm: arm, hand: hand, fold: fold)
    }

    /// One wing, worked out in 3D and seen from the side and a little above:
    /// the near one hangs a little below the body when level, the far one
    /// shows above it. Raised high, the near wing shows its white underside.
    private static func wing(_ ctx: CGContext, near: Bool, arm: CGFloat, hand: CGFloat, fold: CGFloat) {
        let L: CGFloat = 36
        // Seen a little from above and from in front.
        let yaw: CGFloat = 0.5, rise: CGFloat = 0.42
        let side: CGFloat = near ? 1 : -1
        typealias V = (x: CGFloat, y: CGFloat, z: CGFloat)
        func project(_ v: V) -> CGPoint { CGPoint(x: v.x + yaw * v.y, y: -(v.z - rise * v.y)) }
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
        let lead: [(CGFloat, CGFloat)] = [(0, 0), (0.2, -0.02), (0.45, -0.05), (0.7, 0.0), (0.88, 0.07), (1.0, 0.14)]
        let trail: [(CGFloat, CGFloat)] = [(1.0, 0.2), (0.93, 0.27), (0.8, 0.31), (0.6, 0.34), (0.45, 0.37), (0.2, 0.36), (0, 0.33)]
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
        let outline = smooth((lead + trail).map { point($0.0, $0.1) }, closed: true)
        // Which side faces us: the top of the wing, or the white underside.
        let facing = near ? -sin(arm) + rise * cos(arm) : sin(arm) + rise * cos(arm)
        let under = min(1, max(0, 0.5 - facing * 4))
        let top = near ? mantle : farMantle, below = near ? underwing : farUnderwing
        Sprite.fill(ctx, outline, mix(top, below, under))
        // The black tips, with a white spot.
        func interp(_ edge: [(CGFloat, CGFloat)], _ s: CGFloat) -> CGFloat {
            let e = edge.sorted { $0.0 < $1.0 }
            for i in 1..<e.count where s <= e[i].0 {
                let f = (s - e[i - 1].0) / (e[i].0 - e[i - 1].0)
                return e[i - 1].1 + (e[i].1 - e[i - 1].1) * f
            }
            return e.last!.1
        }
        let from: CGFloat = 0.72
        let tipLead = [(from, interp(lead, from))] + lead.filter { $0.0 > from }
        let tipTrail = trail.filter { $0.0 > from } + [(from, interp(trail, from))]
        let tipPath = smooth((tipLead + tipTrail).map { point($0.0, $0.1) }, closed: true)
        Sprite.fill(ctx, tipPath, mix(tip, Sprite.rgba(70, 72, 78, 1), under * 0.4))
        let spot = point(0.94, 0.12)
        Sprite.fill(ctx, Sprite.ellipse(spot.x, spot.y, 1.1, 0.9), Sprite.rgba(255, 255, 255, 0.9))
        // A white trailing edge on top.
        if under < 0.5 {
            let edgeLine = smooth(trail.filter { $0.0 <= from + 0.02 }.reversed().map { point($0.0, $0.1 - 0.02) }, closed: false)
            Sprite.stroke(ctx, edgeLine, Sprite.rgba(255, 255, 255, 0.85 * (1 - under * 2)), width: 1.0)
        }
        Sprite.stroke(ctx, outline, edge, width: 0.55)
    }

    private static func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        guard let ca = a.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              let cb = b.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
              ca.count >= 4, cb.count >= 4 else { return a }
        return CGColor(srgbRed: ca[0] + (cb[0] - ca[0]) * t, green: ca[1] + (cb[1] - ca[1]) * t,
                       blue: ca[2] + (cb[2] - ca[2]) * t, alpha: ca[3] + (cb[3] - ca[3]) * t)
    }
}

private extension CGRect {
    func scaled(_ k: CGFloat) -> CGRect { CGRect(x: minX * k, y: minY * k, width: width * k, height: height * k) }
}

// MARK: - Perches

/// Something a gull can stand on: the line's rope, a garland's wire, or
/// the bottom of the screen, as points along it in screen coordinates.
struct Perch {
    enum Kind: Equatable {
        case rope, garland(UUID), ground
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
/// by, sometimes it lands on the line, on a garland or at the bottom of the
/// screen, looks around, preens, walks a little, and flies off. The rope
/// sags under it and swings when it lands or takes off; its wings stir the
/// bulbs and the candle flames. Double-click it and it follows the pointer
/// until double-clicked again.
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
        guard visit == nil, let screen = GarlandController.lineScreen else { return }
        let v = GullVisit(screen: screen, world: self)
        visit = v
        v.onEnd = { [weak self, weak v] in
            if self?.visit === v { self?.visit = nil }
        }
        v.start()
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        let on = ClosureMenuItem(L("Seagulls visit", "Visitas de gaviotas")) { [weak self] in
            guard let self else { return }
            self.isOn.toggle()
        }
        on.state = isOn ? .on : .off
        menu.addItem(on)
        menu.addItem(ClosureMenuItem(L("Call a seagull now", "Llamar a una gaviota")) { [weak self] in self?.arrive() })
        menu.addItem(.separator())
        let hint = NSMenuItem(title: L("Double-click a seagull to have it follow you",
                                       "Doble clic en la gaviota para que te siga"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
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
        let v = screen.visibleFrame
        result.append(Perch(kind: .ground, points: [CGPoint(x: v.minX, y: v.minY + 1), CGPoint(x: v.maxX, y: v.minY + 1)],
                            margin: 60))
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
        case .ground:
            break
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

    /// Flies off now.
    func leave() {
        following = false
        if case .standing = mode { takeOff() }
        landing = nil
        route = [exitPoint()]
    }

    private func end() {
        guard !gone else { return }
        gone = true
        link?.invalidate()
        link = nil
        if let bent { world.bend(bent.kind, at: bent.at, depth: 0) }
        window.orderOut(nil)
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
        // The line and the garlands more often than the ground.
        var weighted: [(Perch, Double)] = perches.map { p in
            switch p.kind {
            case .rope: (p, 3)
            case .garland: (p, 2.5)
            case .ground: (p, 1)
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
        if landing.perch.kind != .ground {
            bent = (landing.perch.kind, p)
            depthSpeed += 60 * impact
        }
        world.jolt(landing.perch.kind, at: p, strength: 2.6 * Double(impact))
        // Settling the wings stirs the air once more.
        world.air(at: CGPoint(x: x, y: y + GullPictures.lift), velocity: CGVector(dx: facing * 520, dy: -300))
    }

    private func takeOff(away from: CGPoint? = nil) {
        guard case .standing = mode, let perch else { return }
        if let from { facing = from.x > p.x ? -1 : 1 }
        mode = .rising(since: clock)
        pose = .crouch
        depthSpeed += 90
        world.jolt(perch.kind, at: p, strength: 3)
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
                walkTo = x
                walkSpeed = .random(in: 32...52)
            }
        default:
            facing = -facing
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
        let weight: CGFloat = loaded ? 7 : 0
        let steps = 4
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            depthSpeed += (-90 * (depth - weight) - 5 * depthSpeed) * h
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

    private func draw() {
        let picture: GullPictures.Picture
        var pitch: CGFloat = 0
        switch mode {
        case .standing:
            if walkTo != nil {
                picture = pictures.walk[Int(stride) % 4]
            } else {
                picture = pictures.stand[pose] ?? pictures.stand[.idle]!
            }
        case .rising:
            picture = pictures.stand[.crouch]!
        case .flying:
            let legs = landing != nil && route.isEmpty && hypot(p.x - landing!.x, p.y - landing!.perch.y(at: landing!.x)) < 140
            if gliding {
                picture = legs ? pictures.glideLegs : pictures.glide
            } else {
                let i = Int(wingPhase * Double(pictures.flap.count)) % pictures.flap.count
                picture = legs ? pictures.flapLegs[i] : pictures.flap[i]
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
