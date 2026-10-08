import AppKit
import QuartzCore

/// Three candles standing close together on the desktop: the tallest in the
/// middle, a little behind; the shortest on the left and a slightly shorter
/// one on the right, in front and touching it. Like the garlands, they live
/// under every window and only take the mouse while you are editing.
struct CandleSet: Codable, Equatable {
    /// Where the front candles stand, in global screen coordinates: the
    /// bottom of the left candle's wax, on its saucer.
    var position: CGPoint
}

/// How the candles look, set from the Candle appearance menu and saved.
struct CandleStyle: Codable, Equatable {
    enum Wax: String, Codable, CaseIterable {
        case cream, white, ivory, honey

        var title: String {
            switch self {
            case .cream: L("Cream", "Crema")
            case .white: L("White", "Blanca")
            case .ivory: L("Ivory", "Marfil")
            case .honey: L("Honey", "Miel")
            }
        }

        /// Hue, saturation and lightness of the wax, as on the design page.
        var hsl: (CGFloat, CGFloat, CGFloat) {
            switch self {
            case .cream: (42, 0.48, 0.86)
            case .white: (38, 0.14, 0.94)
            case .ivory: (46, 0.38, 0.90)
            case .honey: (34, 0.72, 0.60)
            }
        }
    }

    var wax: Wax = .cream
    /// The unit everything is drawn in, in points. The tallest candle is
    /// seven units of wax.
    var size: CGFloat = 15
    /// How thick the candles are, around 1.
    var thickness: CGFloat = 0.9
    /// How close they stand: below 1 they overlap.
    var tightness: CGFloat = 0.92
    /// Wax drips down each candle.
    var drips = 3
    /// The halo of light around each flame, 0 to 1.5.
    var halo: CGFloat = 1.3
    /// How much the flames move and flicker, 0 to 1.5.
    var flicker: CGFloat = 0.75
    /// Hue of the light in degrees.
    var warmth: CGFloat = 32

    static let defaults = CandleStyle()

    var radius: CGFloat { size * 1.2 * thickness }
    var step: CGFloat { radius * 2 * tightness }

    /// Each candle: its offset from the set's position (y up), its height
    /// as a part of the tallest, and its own seed for drips and rhythm.
    /// Listed back to front, the order they are drawn in.
    var layout: [(dx: CGFloat, dy: CGFloat, height: CGFloat, seed: Int)] {
        [(0, size * 0.55, 1, 2), (-step, 0, 0.62, 1), (step * 1.02, -size * 0.1, 0.82, 3)]
    }

    /// The space the candles take, flames and saucers included, for a set
    /// standing at `position`. Used for clicking on them while editing.
    func bounds(at position: CGPoint) -> CGRect {
        let halfWidth = step * 1.02 + radius * 1.6
        let top = position.y + size * (0.55 + 7 + 2.6)
        let bottom = position.y - size * 1.3
        return CGRect(x: position.x - halfWidth, y: bottom, width: halfWidth * 2, height: top - bottom)
    }
}

/// HSL to a color, as the design pages specify colors.
func hslColor(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) -> CGColor {
    let s = min(max(s, 0), 1), l = min(max(l, 0), 1)
    let v = l + s * min(l, 1 - l)
    let sv = v == 0 ? 0 : 2 * (1 - l / v)
    var hue = h.truncatingRemainder(dividingBy: 360)
    if hue < 0 { hue += 360 }
    return NSColor(hue: hue / 360, saturation: sv, brightness: v, alpha: min(max(a, 0), 1)).cgColor
}

/// Draws the candles. Each candle with its saucer is painted once into an
/// image; so is each flame and halo. On screen only three small flame
/// images sway and stretch and three halos breathe, as slow uneven
/// keyframe loops that Core Animation plays at a calm frame rate.
@MainActor
final class CandleLayers {
    let root = CALayer()
    private var scale: CGFloat = 2

    private struct Pictures {
        let style: CandleStyle
        let scale: CGFloat
        let candles: [(rect: CGRect, image: CGImage?)]
        /// Warm light from each flame on its wax and saucer, which rises and
        /// falls with the flicker.
        let waxLights: [(rect: CGRect, image: CGImage?)]
        let flame: FlamePictures
        let halo: (rect: CGRect, image: CGImage?)
    }
    private var pictures: Pictures?

    /// The parts of each flame on screen, for a draft or a sputter to move.
    private var parts: [(sway: CALayer, stretch: CALayer, halo: CALayer, light: CALayer)] = []
    /// Each flame's response to the air the pointer stirs, so a new gust
    /// starts from where the flame is.
    private var winds: [Wind] = []
    private var unit: CGFloat = 0
    private var draftTimer: Timer?
    private var flickerAmount: Double = 0

    deinit { MainActor.assumeIsolated { draftTimer?.invalidate() } }

    /// `size` is the area to draw in: the cached candles are flattened to it.
    func render(_ set: CandleSet?, style: CandleStyle, origin: CGPoint, size: CGSize, scale: CGFloat) {
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        defer { CATransaction.commit() }
        guard let set else { return }

        let pics = pictures(for: style)
        let u = style.size
        let base = CGPoint(x: set.position.x - origin.x, y: set.position.y - origin.y)
        let still = CALayer()
        still.frame = root.bounds
        var halos: [CALayer] = []
        var flames: [CALayer] = []
        var lights: [CALayer] = []
        parts = []
        winds = []
        unit = u
        flickerAmount = Double(style.flicker)

        for (i, c) in style.layout.enumerated() {
            let foot = CGPoint(x: base.x + c.dx, y: base.y + c.dy)
            let top = foot.y + u * 7 * c.height
            let halo = Sprite.layer(pics.halo.image, rect: pics.halo.rect,
                                    at: CGPoint(x: foot.x, y: top + u * 0.8), scale: scale)
            let flicker = Flicker(seed: c.seed)
            // The halo swells and dims with the flame.
            if style.flicker > 0.01, style.halo > 0.01 {
                let f = Double(style.flicker)
                halo.add(flicker.animation("opacity", around: 0.86, by: 0.14 * f), forKey: "flicker")
                halo.add(flicker.animation("transform.scale", around: 1, by: 0.05 * f), forKey: "swell")
            }
            halos.append(halo)
            still.addSublayer(Sprite.layer(pics.candles[i].image, rect: pics.candles[i].rect, at: foot, scale: scale))
            let light = Sprite.layer(pics.waxLights[i].image, rect: pics.waxLights[i].rect, at: foot, scale: scale)
            if style.flicker > 0.01 {
                light.add(flicker.animation("opacity", around: 0.6, by: 0.4 * Double(style.flicker)), forKey: "flicker")
            }
            lights.append(light)
            let flameLayer = flame(pics.flame, at: CGPoint(x: foot.x, y: top + u * 0.02), style: style,
                                   seed: c.seed, flicker: flicker)
            flames.append(flameLayer)
            if let stretch = flameLayer.sublayers?.first {
                parts.append((flameLayer, stretch, halo, light))
                winds.append(Wind(base: flameLayer.position))
            }
        }
        // The candles never change once drawn: cache them as one bitmap.
        still.shouldRasterize = true
        still.rasterizationScale = scale
        // Halos go under the wax, flames over it.
        halos.forEach { root.addSublayer($0) }
        root.addSublayer(still)
        lights.forEach { root.addSublayer($0) }
        flames.forEach { root.addSublayer($0) }
        if style.flicker > 0.01 { scheduleDraft() }
    }

    // MARK: Pictures

    private func pictures(for st: CandleStyle) -> Pictures {
        if let pictures, pictures.style == st, pictures.scale == scale { return pictures }
        let u = st.size
        let candles = st.layout.map { c -> (CGRect, CGImage?) in
            let r = st.radius * 1.75
            let rect = CGRect(x: -r, y: -u * 7 * c.height - u * 1.2, width: r * 2, height: u * 7 * c.height + u * 2.6)
            return (rect, Sprite.draw(rect, scale: scale) { ctx in
                Self.drawSaucer(ctx, u: u, style: st)
                Self.drawCandle(ctx, u: u, height: c.height, seed: c.seed, style: st)
            })
        }
        let waxLights = st.layout.map { c -> (CGRect, CGImage?) in
            let r = st.radius * 1.75
            let rect = CGRect(x: -r, y: -u * 7 * c.height - u * 1.2, width: r * 2, height: u * 7 * c.height + u * 2.6)
            return (rect, Sprite.draw(rect, scale: scale) { ctx in
                Self.drawWaxLight(ctx, u: u, height: c.height, seed: c.seed, style: st)
            })
        }
        let fu = u * pow(st.thickness, 0.3)
        let flame = Self.flamePictures(u: fu, style: st, scale: scale)
        let r = u * 7
        let haloRect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        let halo = Sprite.draw(haloRect, scale: scale) { ctx in
            let k = st.halo, m: CGFloat = 0.85, w = st.warmth
            Sprite.radial(ctx, center: .zero, radius: r, [
                (0, hslColor(w + 4, 1, 0.68, 0.4 * k * m)),
                (0.18, hslColor(w, 1, 0.6, 0.2 * k * m)),
                (0.5, hslColor(w - 4, 0.95, 0.55, 0.06 * k * m)),
                (1, hslColor(w - 6, 0.9, 0.5, 0)),
            ])
        }
        let made = Pictures(style: st, scale: scale, candles: candles, waxLights: waxLights, flame: flame,
                            halo: (haloRect, halo))
        pictures = made
        return made
    }

    private static func wax(_ st: CandleStyle, _ dl: CGFloat, _ a: CGFloat = 1, ds: CGFloat = 0) -> CGColor {
        let (h, s, l) = st.wax.hsl
        return hslColor(h, s + ds / 100, l + dl / 100, a)
    }

    /// A soft-edged ellipse, for shadows: a radial gradient squashed flat.
    private static func softEllipse(_ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat,
                                    _ color: CGColor, soft: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.scaleBy(x: 1, y: ry / rx)
        let clear = color.copy(alpha: 0) ?? color
        let edge = rx * (1 + soft)
        Sprite.radial(ctx, center: .zero, radius: edge, [(0, color), ((1 - soft) / (1 + soft), color), (1, clear)])
        ctx.restoreGState()
    }

    /// A small ceramic saucer under the candle standing at (0, 0), y down.
    private static func drawSaucer(_ ctx: CGContext, u: CGFloat, style st: CandleStyle) {
        let R = st.radius * 1.55, ry = R * 0.32, y = u * 0.25
        softEllipse(ctx, u * 0.2, y + ry * 0.7, R * 1.02, ry * 1.1, Sprite.rgba(40, 30, 20, 0.16), soft: 0.35)
        let side = CGMutablePath()
        side.addArc(center: .zero, radius: 1, startAngle: 0, endAngle: .pi, clockwise: false,
                    transform: CGAffineTransform(translationX: 0, y: y + u * 0.12).scaledBy(x: R, y: ry))
        side.addLine(to: CGPoint(x: -R, y: y))
        side.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: true,
                    transform: CGAffineTransform(translationX: 0, y: y).scaledBy(x: R, y: ry))
        side.closeSubpath()
        Sprite.fill(ctx, side, Sprite.rgba(217, 211, 201, 1))
        let plate = Sprite.ellipse(0, y, R, ry)
        Sprite.clipped(ctx, plate) {
            Sprite.linear(ctx, from: CGPoint(x: -R, y: y - ry), to: CGPoint(x: R, y: y + ry),
                          [(0, Sprite.rgba(251, 249, 245, 1)), (1, Sprite.rgba(230, 224, 214, 1))])
        }
        let rimLight = CGMutablePath()
        rimLight.addArc(center: .zero, radius: 1, startAngle: .pi * 1.1, endAngle: .pi * 1.9, clockwise: false,
                        transform: CGAffineTransform(translationX: 0, y: y).scaledBy(x: R, y: ry))
        Sprite.stroke(ctx, rimLight, Sprite.rgba(255, 255, 255, 0.8), width: 1)
        Sprite.fill(ctx, Sprite.ellipse(0, y + ry * 0.08, R * 0.72, ry * 0.66), Sprite.rgba(170, 155, 135, 0.22))
        softEllipse(ctx, 0, u * 0.1, st.radius * 1.05, ry * 0.55, Sprite.rgba(30, 20, 10, 0.25), soft: 0.3)
    }

    /// A pillar candle standing at (0, 0), y down: shaded wax that glows
    /// warm under the flame, an uneven melted rim, a crater with a pool of
    /// melted wax reflecting the flame, drips that start with a bulge at
    /// the rim and end in a drop, and the wick.
    /// A candle's outline and its uneven rim, the same for the candle and
    /// for the light that plays on it. Uses the first numbers of `rnd`.
    private static func outline(u: CGFloat, height k: CGFloat, style st: CandleStyle, rnd: inout SeededRandom)
        -> (body: CGPath, rimPoint: (CGFloat) -> CGPoint) {
        let R = st.radius, ry = R * 0.3, h = u * 7 * k, top = -h, base: CGFloat = 0
        let lipAmp = u * 0.12
        let ph0 = rnd.nextCG() * 6, ph1 = rnd.nextCG() * 6
        let lip: (CGFloat) -> CGFloat = { th in lipAmp * (0.6 + 0.4 * sin(th * 3 + ph0) + 0.25 * sin(th * 7 + ph1)) }
        let rimPoint: (CGFloat) -> CGPoint = { th in CGPoint(x: R * sin(th), y: top + ry * cos(th) - lip(th)) }

        // The sides, the front of the bottom, the back of the rim.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -R, y: top - lip(-.pi / 2)))
        body.addLine(to: CGPoint(x: -R, y: base))
        body.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: true,
                    transform: CGAffineTransform(translationX: 0, y: base).scaledBy(x: R, y: ry))
        body.addLine(to: CGPoint(x: R, y: top - lip(.pi / 2)))
        for i in 0...40 { body.addLine(to: rimPoint(.pi / 2 + .pi * CGFloat(i) / 40)) }
        body.closeSubpath()
        return (body, rimPoint)
    }

    /// The flame's own light on its candle and saucer, y down from where the
    /// candle stands: brightest on the rim and the melted pool, fading down
    /// the wax, with a little on the saucer. Layered over the candle and
    /// faded with the flicker, so the wax seems lit by a living flame.
    private static func drawWaxLight(_ ctx: CGContext, u: CGFloat, height k: CGFloat, seed: Int, style st: CandleStyle) {
        let R = st.radius, h = u * 7 * k, top = -h, w = st.warmth
        var rnd = SeededRandom(seed: seed * 7 + 3)
        let shape = outline(u: u, height: k, style: st, rnd: &rnd)
        let rim = CGMutablePath()
        for i in 0...60 {
            let p = shape.rimPoint(.pi * 2 * CGFloat(i) / 60)
            if i == 0 { rim.move(to: p) } else { rim.addLine(to: p) }
        }
        rim.closeSubpath()
        let lit = CGMutablePath()
        lit.addPath(shape.body)
        lit.addPath(rim)
        Sprite.clipped(ctx, lit) {
            Sprite.radial(ctx, from: CGPoint(x: 0, y: top - u * 0.6), r0: 0, to: CGPoint(x: 0, y: top),
                          r1: max(R * 2.2, h * 0.5), [
                (0, hslColor(w + 8, 1, 0.74, 0.5)), (0.5, hslColor(w + 4, 0.95, 0.66, 0.16)), (1, hslColor(w, 0.9, 0.6, 0)),
            ])
        }
        let plateR = st.radius * 1.55
        Sprite.clipped(ctx, Sprite.ellipse(0, u * 0.25, plateR, plateR * 0.32)) {
            Sprite.radial(ctx, center: CGPoint(x: 0, y: u * 0.1), radius: plateR * 1.1, [
                (0, hslColor(w + 6, 1, 0.7, 0.22)), (1, hslColor(w, 0.9, 0.6, 0)),
            ])
        }
    }

    private static func drawCandle(_ ctx: CGContext, u: CGFloat, height k: CGFloat, seed: Int, style st: CandleStyle) {
        let R = st.radius, ry = R * 0.3, h = u * 7 * k, top = -h, base: CGFloat = 0
        var rnd = SeededRandom(seed: seed * 7 + 3)
        let w = st.warmth
        let shape = outline(u: u, height: k, style: st, rnd: &rnd)
        let body = shape.body, rimPoint = shape.rimPoint

        Sprite.clipped(ctx, body) {
            Sprite.linear(ctx, from: CGPoint(x: -R, y: 0), to: CGPoint(x: R, y: 0), [
                (0, wax(st, -20)), (0.18, wax(st, -6)), (0.4, wax(st, 3)), (0.6, wax(st, 1)), (0.85, wax(st, -10)), (1, wax(st, -24)),
            ])
            // Light from the flame shining through the wax.
            Sprite.radial(ctx, from: CGPoint(x: 0, y: top), r0: 0, to: CGPoint(x: 0, y: top + h * 0.15),
                          r1: max(R * 2.6, h * 0.55), [
                (0, hslColor(w + 8, 0.95, 0.7, 0.55)), (0.45, hslColor(w + 4, 0.9, 0.65, 0.18)), (1, hslColor(w, 0.8, 0.6, 0)),
            ])
            // Darker where it meets the saucer.
            Sprite.linear(ctx, from: CGPoint(x: 0, y: base - u * 1.2), to: CGPoint(x: 0, y: base + ry), [
                (0, Sprite.rgba(60, 40, 20, 0)), (1, Sprite.rgba(60, 40, 20, 0.18)),
            ])
            // A few faint streaks in the wax.
            let streaks = CGMutablePath()
            for _ in 0..<9 {
                let xx = -R + R * 2 * rnd.nextCG()
                streaks.move(to: CGPoint(x: xx, y: top))
                streaks.addLine(to: CGPoint(x: xx + (rnd.nextCG() - 0.5) * u * 0.2, y: base))
            }
            Sprite.stroke(ctx, streaks, Sprite.rgba(0, 0, 0, 0.035), width: 0.6, cap: .butt)
        }

        // The top: the rim all round, the crater and the melted pool.
        let rim = CGMutablePath()
        for i in 0...60 {
            let p = rimPoint(.pi * 2 * CGFloat(i) / 60)
            if i == 0 { rim.move(to: p) } else { rim.addLine(to: p) }
        }
        rim.closeSubpath()
        Sprite.fill(ctx, rim, wax(st, -2))
        Sprite.clipped(ctx, Sprite.ellipse(0, top, R * 0.9, ry * 0.9)) {
            Sprite.radial(ctx, from: CGPoint(x: 0, y: top), r0: R * 0.2, to: CGPoint(x: 0, y: top), r1: R * 0.95, [
                (0, wax(st, -10, 0)), (0.7, wax(st, -14, 0.35)), (1, wax(st, 4, 0.6)),
            ])
        }
        Sprite.clipped(ctx, Sprite.ellipse(0, top + ry * 0.08, R * 0.62, ry * 0.6)) {
            Sprite.radial(ctx, center: CGPoint(x: 0, y: top), radius: R * 0.62, [
                (0, hslColor(w + 10, 1, 0.84, 0.95)), (0.7, hslColor(w + 4, 0.85, 0.74, 0.75)), (1, wax(st, -4, 0.6, ds: 10)),
            ])
        }
        Sprite.fill(ctx, Sprite.ellipse(0, top + ry * 0.32, R * 0.12, ry * 0.12), Sprite.rgba(255, 252, 235, 0.85))
        let frontRim = CGMutablePath()
        for i in 0...30 {
            let p = rimPoint(-.pi / 2 + .pi * CGFloat(i) / 30)
            if i == 0 { frontRim.move(to: p) } else { frontRim.addLine(to: p) }
        }
        Sprite.stroke(ctx, frontRim, wax(st, 9, 0.85), width: max(0.8, u * 0.1))

        // Drips.
        for _ in 0..<max(0, st.drips) {
            let th = (rnd.nextCG() * 2 - 1) * 1.15
            let f = cos(th)
            let p0 = rimPoint(th)
            let x0 = p0.x, y0 = p0.y + u * 0.02
            let w0 = u * (0.27 + rnd.nextCG() * 0.17) * f * st.thickness
            let L = min(h * 0.75, u * (0.7 + rnd.nextCG() * 2.8))
            let bulb = w0 * (0.62 + rnd.nextCG() * 0.25)
            let ex = x0 + (rnd.nextCG() - 0.5) * w0 * 0.6, ey = y0 + L
            let drip = CGMutablePath()
            drip.move(to: CGPoint(x: x0 - w0 * 0.65, y: y0 - u * 0.06))
            drip.addCurve(to: CGPoint(x: ex - bulb * 0.75, y: ey - bulb * 0.6),
                          control1: CGPoint(x: x0 - w0 * 0.5, y: y0 + L * 0.25), control2: CGPoint(x: ex - w0 * 0.28, y: ey - L * 0.35))
            drip.addCurve(to: CGPoint(x: ex + bulb * 0.2, y: ey + bulb * 0.85),
                          control1: CGPoint(x: ex - bulb * 1.05, y: ey + bulb * 0.2), control2: CGPoint(x: ex - bulb * 0.3, y: ey + bulb * 1.05))
            drip.addCurve(to: CGPoint(x: ex + bulb * 0.55, y: ey - bulb * 0.75),
                          control1: CGPoint(x: ex + bulb * 0.95, y: ey + bulb * 0.5), control2: CGPoint(x: ex + bulb * 0.95, y: ey - bulb * 0.3))
            drip.addCurve(to: CGPoint(x: x0 + w0 * 0.65, y: y0 - u * 0.06),
                          control1: CGPoint(x: ex + w0 * 0.28, y: ey - L * 0.35), control2: CGPoint(x: x0 + w0 * 0.5, y: y0 + L * 0.25))
            drip.closeSubpath()

            var shift = CGAffineTransform(translationX: u * 0.06, y: u * 0.05)
            if let shadow = drip.copy(using: &shift) { Sprite.fill(ctx, shadow, Sprite.rgba(0, 0, 0, 0.07)) }
            Sprite.clipped(ctx, drip) {
                Sprite.linear(ctx, from: CGPoint(x: x0 - w0, y: 0), to: CGPoint(x: x0 + w0, y: 0), [
                    (0, wax(st, -6)), (0.4, wax(st, 6)), (0.7, wax(st, 3)), (1, wax(st, -10)),
                ])
                Sprite.linear(ctx, from: CGPoint(x: 0, y: y0), to: CGPoint(x: 0, y: ey), [
                    (0, hslColor(w + 8, 0.95, 0.72, 0.4)), (1, hslColor(w, 0.8, 0.65, 0)),
                ])
            }
            let gleam = CGMutablePath()
            gleam.move(to: CGPoint(x: x0 - w0 * 0.18, y: y0 + u * 0.1))
            gleam.addQuadCurve(to: CGPoint(x: ex - bulb * 0.3, y: ey - bulb * 0.1), control: CGPoint(x: ex - bulb * 0.25, y: ey - L * 0.4))
            Sprite.stroke(ctx, gleam, Sprite.rgba(255, 255, 255, 0.3), width: max(0.5, w0 * 0.14))
            Sprite.fill(ctx, Sprite.ellipse(ex - bulb * 0.3, ey + bulb * 0.1, bulb * 0.18, bulb * 0.25), Sprite.rgba(255, 255, 255, 0.5))
            Sprite.fill(ctx, Sprite.ellipse(x0, y0 - u * 0.02, w0 * 0.8, u * 0.1), wax(st, 5))
        }

        // The wick, with its glowing tip.
        let tip = CGPoint(x: 0, y: top - u * 0.02)
        let wick = CGMutablePath()
        wick.move(to: CGPoint(x: 0, y: tip.y + u * 0.2))
        wick.addQuadCurve(to: CGPoint(x: 0, y: tip.y - u * 0.14), control: CGPoint(x: u * 0.03, y: tip.y))
        Sprite.stroke(ctx, wick, Sprite.rgba(23, 17, 12, 1), width: max(1, u * 0.075))
        Sprite.fill(ctx, Sprite.ellipse(0, tip.y - u * 0.15, max(0.6, u * 0.04), max(0.6, u * 0.04)), hslColor(w - 16, 1, 0.55, 0.95))
    }

    /// The flame standing on (0, 0), y down, as a loop of frames: its tip
    /// bends and flutters, it grows taller and thinner and shrinks back, its
    /// waist narrows. Each frame is the flame itself, a white core and a
    /// little blue at the base, softened with a blur once, when it is made.
    /// The soft orange glow around it is a picture of its own, so its
    /// strength can change: redder as the flame dips, whiter as it flares.
    struct FlamePictures {
        let rect: CGRect
        let frames: [CGImage]
        let glow: CGImage?
    }

    /// Played 24 a second, so the flame changes shape smoothly.
    static let flameFrames = 48

    private static func flamePictures(u: CGFloat, style st: CandleStyle, scale: CGFloat) -> FlamePictures {
        let w = st.warmth
        let h = u * 1.95, fw = u * 0.31
        let pad = u * 0.9
        let rect = Sprite.aligned(CGRect(x: -fw * 2.4 - pad, y: -h * 1.2 - pad, width: (fw * 2.4 + pad) * 2,
                                         height: h * 1.2 + u * 0.4 + pad * 2), scale: scale)
        /// A flame of half width `ww` and height `hh`, its tip moved `tip`
        /// sideways, `waist` how far in its upper sides come.
        /// Round at the bottom, widest a third of the way up, then drawn
        /// out into a fine point, as a candle flame is.
        func shape(_ ww: CGFloat, _ hh: CGFloat, tip: CGFloat, waist: CGFloat, dy: CGFloat = 0) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: dy + ww * 0.25))
            p.addCurve(to: CGPoint(x: -ww * 0.95, y: dy - hh * 0.34),
                       control1: CGPoint(x: -ww * 0.5, y: dy + ww * 0.2), control2: CGPoint(x: -ww * 1.0, y: dy - hh * 0.12))
            p.addCurve(to: CGPoint(x: tip, y: dy - hh),
                       control1: CGPoint(x: -ww * 0.85 * waist + tip * 0.45, y: dy - hh * 0.55),
                       control2: CGPoint(x: tip - ww * 0.1, y: dy - hh * 0.84))
            p.addCurve(to: CGPoint(x: ww * 0.95, y: dy - hh * 0.34),
                       control1: CGPoint(x: tip + ww * 0.1, y: dy - hh * 0.84),
                       control2: CGPoint(x: ww * 0.85 * waist + tip * 0.45, y: dy - hh * 0.55))
            p.addCurve(to: CGPoint(x: 0, y: dy + ww * 0.25),
                       control1: CGPoint(x: ww * 1.0, y: dy - hh * 0.12), control2: CGPoint(x: ww * 0.5, y: dy + ww * 0.2))
            p.closeSubpath()
            return p
        }
        func soft(_ blur: CGFloat, _ body: @escaping (CGContext) -> Void) -> CGImage? {
            guard let image = Sprite.draw(rect, scale: scale, body) else { return nil }
            return Sprite.blurred(image, radius: blur * scale)
        }
        let size = CGSize(width: (rect.width * scale).rounded(.up), height: (rect.height * scale).rounded(.up))
        // Just a faint blue rim at the very bottom, where the flame meets the air.
        let blue = soft(max(0.3, u * 0.05)) { ctx in
            Sprite.fill(ctx, Sprite.ellipse(0, -u * 0.02, fw * 0.5, u * 0.09), Sprite.rgba(110, 150, 255, 0.28))
        }
        // Whole cycles of a slow lean, a quicker sway and a fast flutter at
        // the tip, so the loop has no seam.
        let frames: [CGImage] = (0..<flameFrames).compactMap { k in
            let t = 2 * CGFloat.pi * CGFloat(k) / CGFloat(flameFrames)
            let bend = 0.22 * sin(t + 0.7) + 0.14 * sin(3 * t + 2.1) + 0.1 * sin(7 * t + 4)
            let tip = bend * fw * 2.2
            let tall = 1 + 0.09 * sin(2 * t + 1.3) + 0.05 * sin(5 * t + 0.4)
            let wide = 1 - 0.07 * sin(2 * t + 1.3) + 0.04 * sin(4 * t + 2.8)
            let waist = 0.85 + 0.08 * sin(3 * t + 5.1)
            // Little blur: soft edges, but the bright core stays crisp.
            let main = soft(max(0.25, u * 0.025)) { ctx in
                Sprite.clipped(ctx, shape(fw * wide, h * tall, tip: tip, waist: waist)) {
                    // Dim and see-through by the wick, bright yellow in the
                    // middle, deepening to orange and fading at the point.
                    Sprite.linear(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: tip, y: -h * tall), [
                        (0, hslColor(w - 4, 0.9, 0.55, 0.45)), (0.16, hslColor(w + 8, 1, 0.72, 0.9)),
                        (0.4, hslColor(w + 6, 1, 0.68, 0.97)), (0.78, hslColor(w - 6, 1, 0.56, 0.85)),
                        (1, hslColor(w - 14, 1, 0.5, 0.15)),
                    ])
                }
            }
            let core = soft(max(0.25, u * 0.04)) { ctx in
                // The white-hot core sits a little above the wick.
                let lift = u * 0.2
                Sprite.clipped(ctx, shape(fw * 0.42 * wide, h * 0.6 * tall, tip: tip * 0.5, waist: waist, dy: -lift)) {
                    Sprite.linear(ctx, from: CGPoint(x: 0, y: -lift), to: CGPoint(x: tip * 0.5, y: -lift - h * 0.6 * tall), [
                        (0, Sprite.rgba(255, 252, 235, 0.55)), (0.3, Sprite.rgba(255, 255, 250, 1)),
                        (1, Sprite.rgba(255, 246, 215, 0.5)),
                    ])
                }
            }
            return Sprite.stack([main, core, blue], size: size)
        }
        let glow = soft(max(0.6, u * 0.22)) { ctx in
            Sprite.fill(ctx, shape(fw * 1.3, h * 1.05, tip: 0, waist: 0.85), hslColor(w - 10, 1, 0.52, 0.32))
        }
        return FlamePictures(rect: rect, frames: frames, glow: glow)
    }

    // MARK: Motion

    /// The flame sways from its base on a slow loop of its own, and on the
    /// candle's flicker it stretches taller and burns brighter, together,
    /// as a real flame does; its halo follows the same flicker.
    private func flame(_ pic: FlamePictures, at tip: CGPoint, style st: CandleStyle,
                       seed: Int, flicker: Flicker) -> CALayer {
        let rect = pic.rect
        let sway = CALayer()
        sway.bounds = CGRect(origin: .zero, size: rect.size)
        sway.anchorPoint = CGPoint(x: -rect.minX / rect.width, y: rect.maxY / rect.height)
        sway.position = Sprite.snap(tip, scale: scale)
        let stretch = CALayer()
        stretch.bounds = sway.bounds
        stretch.anchorPoint = sway.anchorPoint
        stretch.position = CGPoint(x: -rect.minX, y: rect.maxY)
        sway.addSublayer(stretch)
        let glow = Sprite.layer(pic.glow, rect: rect, at: CGPoint(x: -rect.minX, y: rect.maxY), scale: scale)
        let body = Sprite.layer(pic.frames.first, rect: rect, at: CGPoint(x: -rect.minX, y: rect.maxY), scale: scale)
        stretch.addSublayer(glow)
        stretch.addSublayer(body)

        let f = Double(st.flicker)
        guard f > 0.01 else { return sway }
        var r = SeededRandom(seed: seed * 13 + 5)
        // The shape: frames played in a loop, each candle at its own pace
        // and from its own frame.
        let shape = CAKeyframeAnimation(keyPath: "contents")
        shape.values = pic.frames
        shape.calculationMode = .discrete
        shape.duration = Double(pic.frames.count) / 24 * (0.9 + 0.12 * Double(seed))
        shape.repeatCount = .infinity
        shape.isRemovedOnCompletion = false
        shape.beginTime = CACurrentMediaTime() - r.next() * shape.duration
        shape.calm()
        body.add(shape, forKey: "shape")
        sway.add(loop("transform.rotation.z", around: 0, by: 0.08 * f, duration: 2.3 + Double(seed) * 0.37, random: &r), forKey: "sway")
        stretch.add(flicker.animation("transform.scale.y", around: 1, by: 0.08 * f), forKey: "stretch")
        body.add(flicker.animation("opacity", around: 0.92, by: 0.08 * f), forKey: "bright")
        // Redder glow as the flame dips, less as it flares.
        glow.add(flicker.animation("opacity", around: 0.75, by: -0.25 * f), forKey: "ember")
        return sway
    }

    // MARK: Air from the pointer

    /// One flame in the moving air: how far it leans and how far it is
    /// smothered, each as a curve, kept so a new gust continues from where
    /// the flame is instead of jumping.
    struct Wind {
        let base: CGPoint
        var lean: [Double] = []
        var leanStart: CFTimeInterval = 0
        var dip: [Double] = []
        var dipStart: CFTimeInterval = 0
        static let step = 1.0 / 30

        static func value(_ curve: [Double], since start: CFTimeInterval) -> Double {
            guard !curve.isEmpty else { return 0 }
            let t = (CACurrentMediaTime() - start) / step
            if t >= Double(curve.count - 1) { return 0 }
            let i = Int(t), f = t - Double(i)
            return curve[i] + (curve[i + 1] - curve[i]) * f
        }
        var currentLean: Double { Self.value(lean, since: leanStart) }
        /// How smothered the flame is now, 0 to 1.
        var currentDip: Double { -Self.value(dip, since: dipStart) / 0.75 }
    }

    /// A hand passing by. Each flame within reach leans the way the air
    /// moves, more the closer and the faster, trembling while the air is
    /// rough, and swings back upright like a pendulum. Fast waving smothers
    /// it: gusts add up, the flame sinks low, thin and dim, almost out, its
    /// halo and the light on the wax fading with it; when the air is still
    /// it grows back, slower after a deeper smothering, flares a little
    /// above its size and settles. All of it played by Core Animation as
    /// additive curves on top of the flicker, worked out once per gust.
    func feelAir(at p: CGPoint, velocity v: CGVector) {
        guard flickerAmount > 0.01, !winds.isEmpty, root.superlayer?.speed != 0 else { return }
        let speed = hypot(v.dx, v.dy)
        guard speed > 30 else { return }
        let reach = unit * 14
        let now = CACurrentMediaTime()
        for (i, wind) in winds.enumerated() where i < parts.count {
            // The flame and its glow sit above the wick.
            let d = hypot(p.x - wind.base.x, p.y - (wind.base.y + unit * 0.8))
            guard d < reach else { continue }
            // At most 30 new curves a second, however fast the mouse reports.
            guard now - max(wind.leanStart, wind.dipStart) >= Wind.step else { continue }
            let near = pow(1 - d / reach, 1.6)
            let strength = min(1.2, Double(speed) / 800) * Double(near)
            guard strength > 0.03 else { continue }
            var rnd = SeededRandom(seed: Int(now * 1000) &+ i)

            // Lean: air moving right pushes the tip right, a clockwise turn,
            // which is negative with y up. Mostly sideways air leans it most.
            let sideways = Double(v.dx / max(speed, 1))
            let lean = wind.currentLean
            let target = max(-0.65, min(0.65, lean - sideways * 0.6 * strength))
            if abs(target - lean) > 0.04 || abs(lean) < 0.02 {
                let curve = Self.leanCurve(from: lean, to: target, rough: strength, random: &rnd)
                winds[i].lean = curve
                winds[i].leanStart = now
                parts[i].sway.add(windAnimation("transform.rotation.z", curve), forKey: "wind")
            }

            // Smothering builds up over time, only in fast air close by:
            // about one and a half to two seconds of fast waving bring the
            // flame near out. Slower air only bends it. It fades on its own.
            let fast = max(0, strength - 0.35)
            let smothered = min(1, wind.currentDip + fast * Wind.step * 0.9)
            if smothered > wind.currentDip + 0.005 {
                let curve = Self.dipCurve(from: wind.currentDip, to: smothered)
                winds[i].dip = curve
                winds[i].dipStart = now
                let part = parts[i]
                part.stretch.add(windAnimation("transform.scale.y", curve), forKey: "wind")
                part.stretch.add(windAnimation("transform.scale.x", curve.map { $0 * 0.45 }), forKey: "windx")
                part.stretch.add(windAnimation("opacity", curve.map { $0 * 0.35 }), forKey: "winddim")
                let dim = curve.map { $0 * 0.9 }
                part.halo.add(windAnimation("opacity", dim), forKey: "wind")
                part.light.add(windAnimation("opacity", dim), forKey: "wind")
            }
        }
    }

    /// Over to `b` in a moment, trembling while the air is rough, then a
    /// lively damped swing back to upright.
    private static func leanCurve(from a: Double, to b: Double, rough: Double, random r: inout SeededRandom) -> [Double] {
        let step = Wind.step
        let out = (0...3).map { i -> Double in
            let t = Double(i) / 3
            return a + (b - a) * (1 - (1 - t) * (1 - t))
        }
        let k = 22.0, c = 2.6
        let wd = (k - c * c / 4).squareRoot(), decay = c / 2
        let n = Int(2.6 / step)
        let back = (1...n).map { i -> Double in
            let t = Double(i) * step
            let swing = b * exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
            // Rough air: a quick tremble that dies away in half a second.
            let tremble = (r.next() * 2 - 1) * 0.12 * min(1, rough) * exp(-t * 5)
            return swing + tremble
        }
        return out + back + [0]
    }

    /// Down to smothered `b` (0 to 1) quickly, then growing back: slowly at
    /// first, longer after a deeper smothering, overshooting into a small
    /// flare before settling. In additive scale, 0 is the flame as it is.
    private static func dipCurve(from a: Double, to b: Double) -> [Double] {
        let step = Wind.step
        let depth = 0.75
        let down = (0...3).map { i -> Double in
            let t = Double(i) / 3
            return -depth * (a + (b - a) * t)
        }
        // Stays low a moment, then rises with an ease-in-out to a flare.
        let hold = max(1, Int((0.05 + 0.1 * b) / step))
        let rise = max(2, Int((0.3 + 0.4 * b) / step))
        let settle = Int(0.4 / step)
        let low = -depth * b, flare = 0.07 * b
        let held = Array(repeating: low, count: hold)
        let up = (1...rise).map { i -> Double in
            let t = Double(i) / Double(rise)
            let e = t * t * (3 - 2 * t)
            return low + (flare - low) * e
        }
        let calm = (1...settle).map { i -> Double in
            let t = Double(i) / Double(settle)
            return flare * (1 - t * t * (3 - 2 * t))
        }
        return down + held + up + calm + [0]
    }

    private func windAnimation(_ keyPath: String, _ values: [Double]) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.calculationMode = .linear
        a.duration = Wind.step * Double(values.count - 1)
        a.isAdditive = true
        if #available(macOS 12.0, *) {
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        }
        return a
    }

    // MARK: Drafts

    /// Every so often a draft: all flames lean the same way and dip, one
    /// after another, then straighten. Now and then just one flame
    /// sputters, almost going out, and recovers. A single timer, firing
    /// every 20 to 60 seconds.
    private func scheduleDraft() {
        guard draftTimer == nil else { return }
        let timer = Timer(timeInterval: .random(in: 20...60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.draftTimer = nil
                self.draft()
                if self.flickerAmount > 0.01 { self.scheduleDraft() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        draftTimer = timer
    }

    private func draft() {
        // Nothing to see while the window is paused or hidden.
        guard !parts.isEmpty, root.superlayer?.speed != 0 else { return }
        // Not while a hand is fanning the flames: the two would add up and
        // could squash a flame past nothing.
        guard winds.allSatisfy({ $0.currentDip < 0.05 && abs($0.currentLean) < 0.05 }) else { return }
        let f = flickerAmount
        if Double.random(in: 0...1) < 0.7 {
            let side: Double = Bool.random() ? 1 : -1
            let times: [NSNumber] = [0, 0.18, 0.35, 0.5, 0.7, 0.85, 1]
            for (i, p) in parts.enumerated() {
                let delay = Double(i) * 0.07
                p.sway.add(additive("transform.rotation.z", [0, 0.22, 0.12, 0.17, 0.05, -0.03, 0].map { $0 * side * f },
                                    times, 1.8, delay), forKey: "draft")
                p.stretch.add(additive("transform.scale.y", [0, -0.15, -0.06, -0.1, -0.02, 0.02, 0].map { $0 * f },
                                       times, 1.8, delay), forKey: "draft")
                let dim = [0, -0.14, -0.06, -0.1, -0.02, 0.02, 0].map { $0 * f }
                p.halo.add(additive("opacity", dim, times, 1.8, delay), forKey: "draft")
                p.light.add(additive("opacity", dim, times, 1.8, delay), forKey: "draft")
            }
        } else if let p = parts.randomElement() {
            let times: [NSNumber] = [0, 0.15, 0.35, 0.55, 0.8, 1]
            p.stretch.add(additive("transform.scale.y", [0, -0.5, -0.35, -0.55, -0.1, 0].map { $0 * f },
                                   times, 0.9, 0), forKey: "draft")
            p.stretch.add(additive("opacity", [0, -0.35, -0.25, -0.4, -0.05, 0].map { $0 * f },
                                   times, 0.9, 0), forKey: "sputter")
            let dim = [0, -0.3, -0.2, -0.35, -0.05, 0].map { $0 * f }
            p.halo.add(additive("opacity", dim, times, 0.9, 0), forKey: "draft")
            p.light.add(additive("opacity", dim, times, 0.9, 0), forKey: "draft")
        }
    }

    private func additive(_ keyPath: String, _ values: [Double], _ times: [NSNumber],
                          _ duration: Double, _ delay: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times
        a.calculationMode = .cubic
        a.duration = duration
        a.isAdditive = true
        a.beginTime = CACurrentMediaTime() + delay
        if #available(macOS 12.0, *) {
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        }
        return a
    }

    /// A repeating, uneven wobble: a dozen random values around a centre,
    /// eased between, ending where it started so the loop has no seam.
    private func loop(_ keyPath: String, around center: Double, by amount: Double, duration: Double,
                      random r: inout SeededRandom) -> CAKeyframeAnimation {
        let steps = 12
        var values = (0..<steps).map { _ in center + (r.next() * 2 - 1) * amount }
        values.append(values[0])
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.calculationMode = .cubic
        a.duration = duration
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.beginTime = CACurrentMediaTime() - r.next() * duration
        a.calm()
        return a
    }
}

/// One candle's flicker: a single uneven curve of intensity from -1 to 1,
/// shared by the flame's height and brightness and by its halo, so they
/// rise and fall together. A slow breath, a quicker waver and small random
/// jumps, built from whole cycles so the loop has no seam.
@MainActor
struct Flicker {
    let values: [Double]
    let duration: Double
    let begin: CFTimeInterval

    init(seed: Int) {
        var r = SeededRandom(seed: seed * 31 + 7)
        let steps = 30
        let p1 = r.next() * 2 * .pi, p2 = r.next() * 2 * .pi
        var v = (0..<steps).map { k -> Double in
            let t = 2 * Double.pi * Double(k) / Double(steps)
            let n = 0.55 * sin(2 * t + p1) + 0.3 * sin(5 * t + p2) + 0.35 * (r.next() * 2 - 1)
            return min(1, max(-1, n))
        }
        v.append(v[0])
        values = v
        duration = 2.4 + Double(seed) * 0.33
        begin = CACurrentMediaTime() - r.next() * duration
    }

    func animation(_ keyPath: String, around center: Double, by amount: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values.map { center + $0 * amount }
        a.calculationMode = .cubic
        a.duration = duration
        a.repeatCount = .infinity
        a.isRemovedOnCompletion = false
        a.beginTime = begin
        a.calm()
        return a
    }
}

/// A small repeatable random sequence, so each candle keeps its own drips
/// and its own rhythm every time it is drawn.
struct SeededRandom {
    private var state: UInt64

    init(seed: Int) { state = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 97) | 1 }

    /// A value in 0..<1.
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func nextCG() -> CGFloat { CGFloat(next()) }
}
