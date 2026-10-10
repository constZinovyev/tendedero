import AppKit

/// A small fish hung by its tail, head down, as if hung out to dry: a
/// blue-gray back, a silver belly with a bit of sheen, a forked tail at the
/// top and a dark eye near the bottom. Now and then one hangs on a garland
/// in place of a bulb, until a seagull comes for it.
enum FishSprite {
    struct Picture {
        let image: CGImage?
        /// Around the point it hangs from (the tail's fork), y down.
        let rect: CGRect
        /// From the tail to the head.
        let length: CGFloat
    }

    @MainActor private static var cache: [String: Picture] = [:]

    /// The fish `length` points long, drawn for `scale`.
    @MainActor static func picture(length: CGFloat, scale: CGFloat) -> Picture {
        let key = "\(length)@\(scale)"
        if let p = cache[key] { return p }
        let w = length * 0.36
        let rect = CGRect(x: -w * 0.9, y: -1, width: w * 1.8, height: length + 3)
        let image = Sprite.draw(rect, scale: scale) { ctx in
            ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * scale), blur: 1.4 * scale, color: Sprite.rgba(0, 0, 0, 0.25))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(ctx, length: length)
            ctx.endTransparencyLayer()
        }
        let p = Picture(image: image, rect: Sprite.aligned(rect, scale: scale), length: length)
        cache[key] = p
        return p
    }

    /// Drawn hanging from (0, 0), y down: the tail at the top.
    private static func draw(_ ctx: CGContext, length L: CGFloat) {
        let w = L * 0.36
        let tailEnd = L * 0.2, head = L

        // The forked tail, gray-blue, with fine rays.
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: 0, y: tailEnd + L * 0.04))
        tail.addQuadCurve(to: CGPoint(x: -w * 0.62, y: 0), control: CGPoint(x: -w * 0.2, y: tailEnd * 0.5))
        tail.addQuadCurve(to: CGPoint(x: 0, y: tailEnd * 0.45), control: CGPoint(x: -w * 0.2, y: tailEnd * 0.2))
        tail.addQuadCurve(to: CGPoint(x: w * 0.62, y: 0), control: CGPoint(x: w * 0.2, y: tailEnd * 0.2))
        tail.addQuadCurve(to: CGPoint(x: 0, y: tailEnd + L * 0.04), control: CGPoint(x: w * 0.2, y: tailEnd * 0.5))
        tail.closeSubpath()
        Sprite.clipped(ctx, tail) {
            Sprite.linear(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: tailEnd),
                          [(0, Sprite.rgba(120, 140, 158, 0.85)), (1, Sprite.rgba(78, 100, 122, 1))])
            for dx in stride(from: -w * 0.5, through: w * 0.5, by: w * 0.18) {
                let ray = CGMutablePath()
                ray.move(to: CGPoint(x: 0, y: tailEnd))
                ray.addLine(to: CGPoint(x: dx, y: 0))
                Sprite.stroke(ctx, ray, Sprite.rgba(40, 56, 72, 0.3), width: 0.25)
            }
        }

        // The body: narrow at the tail, widest past the middle, a rounded
        // snout at the bottom.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 0, y: tailEnd - L * 0.02))
        body.addCurve(to: CGPoint(x: w * 0.5, y: L * 0.66), control1: CGPoint(x: w * 0.18, y: L * 0.3),
                      control2: CGPoint(x: w * 0.52, y: L * 0.48))
        body.addCurve(to: CGPoint(x: 0, y: head), control1: CGPoint(x: w * 0.48, y: L * 0.86),
                      control2: CGPoint(x: w * 0.2, y: head))
        body.addCurve(to: CGPoint(x: -w * 0.5, y: L * 0.66), control1: CGPoint(x: -w * 0.2, y: head),
                      control2: CGPoint(x: -w * 0.48, y: L * 0.86))
        body.addCurve(to: CGPoint(x: 0, y: tailEnd - L * 0.02), control1: CGPoint(x: -w * 0.52, y: L * 0.48),
                      control2: CGPoint(x: -w * 0.18, y: L * 0.3))
        body.closeSubpath()
        Sprite.clipped(ctx, body) {
            // The dark back on the left, the silver belly on the right.
            Sprite.linear(ctx, from: CGPoint(x: -w * 0.5, y: 0), to: CGPoint(x: w * 0.5, y: 0),
                          [(0, Sprite.rgba(52, 76, 98, 1)), (0.38, Sprite.rgba(104, 132, 156, 1)),
                           (0.62, Sprite.rgba(206, 216, 224, 1)), (1, Sprite.rgba(236, 240, 242, 1))])
            // A line of sheen along the side.
            let sheen = CGMutablePath()
            sheen.move(to: CGPoint(x: -w * 0.02, y: L * 0.28))
            sheen.addQuadCurve(to: CGPoint(x: w * 0.06, y: L * 0.9), control: CGPoint(x: w * 0.12, y: L * 0.6))
            Sprite.stroke(ctx, sheen, Sprite.rgba(255, 255, 255, 0.55), width: max(0.5, w * 0.1))
            // Dark spots on the back, like a mackerel's.
            var rnd = SeededRandom(seed: 17)
            for _ in 0..<7 {
                let y = L * (0.3 + 0.45 * rnd.nextCG())
                let x = -w * (0.18 + 0.25 * rnd.nextCG())
                Sprite.fill(ctx, Sprite.ellipse(x, y, w * 0.07, L * 0.025, rotation: 0.3), Sprite.rgba(30, 44, 60, 0.55))
            }
            // The gill cover.
            let gill = CGMutablePath()
            gill.addArc(center: CGPoint(x: 0, y: L * 1.02), radius: L * 0.2, startAngle: -.pi * 0.85, endAngle: -.pi * 0.15, clockwise: false)
            Sprite.stroke(ctx, gill, Sprite.rgba(40, 56, 72, 0.45), width: 0.4)
            Sprite.stroke(ctx, body, Sprite.rgba(28, 40, 54, 0.55), width: 0.9)
        }
        // A small fin on each side.
        for side: CGFloat in [-1, 1] {
            let fin = CGMutablePath()
            fin.move(to: CGPoint(x: side * w * 0.42, y: L * 0.62))
            fin.addQuadCurve(to: CGPoint(x: side * w * 0.42, y: L * 0.48), control: CGPoint(x: side * w * 0.85, y: L * 0.5))
            fin.closeSubpath()
            Sprite.fill(ctx, fin, Sprite.rgba(110, 132, 150, 0.85))
        }
        // The eye, near the snout.
        let eye = CGPoint(x: w * 0.17, y: L * 0.85)
        let mouth = CGMutablePath()
        mouth.move(to: CGPoint(x: w * 0.02, y: head - L * 0.01))
        mouth.addLine(to: CGPoint(x: w * 0.2, y: head - L * 0.05))
        Sprite.stroke(ctx, mouth, Sprite.rgba(28, 40, 54, 0.7), width: 0.4)
        Sprite.fill(ctx, Sprite.ellipse(eye.x, eye.y, w * 0.11, w * 0.11), Sprite.rgba(232, 226, 200, 1))
        Sprite.fill(ctx, Sprite.ellipse(eye.x, eye.y, w * 0.07, w * 0.07), Sprite.rgba(16, 16, 18, 1))
        Sprite.fill(ctx, Sprite.ellipse(eye.x + w * 0.03, eye.y - w * 0.03, w * 0.03, w * 0.03), Sprite.rgba(255, 255, 255, 0.9))
    }
}
