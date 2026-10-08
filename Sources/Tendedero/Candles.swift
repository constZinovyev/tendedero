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
        let flames: [(rect: CGRect, image: CGImage?)]
        let halo: (rect: CGRect, image: CGImage?)
    }
    private var pictures: Pictures?

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
            flames.append(flame(pics.flames[i], at: CGPoint(x: foot.x, y: top + u * 0.02), style: style,
                                seed: c.seed, flicker: flicker))
        }
        // The candles never change once drawn: cache them as one bitmap.
        still.shouldRasterize = true
        still.rasterizationScale = scale
        // Halos go under the wax, flames over it.
        halos.forEach { root.addSublayer($0) }
        root.addSublayer(still)
        flames.forEach { root.addSublayer($0) }
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
        let fu = u * pow(st.thickness, 0.3)
        let flames = st.layout.map { _ in Self.flamePicture(u: fu, style: st, scale: scale) }
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
        let made = Pictures(style: st, scale: scale, candles: candles, flames: flames, halo: (haloRect, halo))
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
    private static func drawCandle(_ ctx: CGContext, u: CGFloat, height k: CGFloat, seed: Int, style st: CandleStyle) {
        let R = st.radius, ry = R * 0.3, h = u * 7 * k, top = -h, base: CGFloat = 0
        var rnd = SeededRandom(seed: seed * 7 + 3)
        let w = st.warmth
        let lipAmp = u * 0.12
        let ph0 = rnd.nextCG() * 6, ph1 = rnd.nextCG() * 6
        let lip: (CGFloat) -> CGFloat = { th in lipAmp * (0.6 + 0.4 * sin(th * 3 + ph0) + 0.25 * sin(th * 7 + ph1)) }
        let rimPoint: (CGFloat) -> CGPoint = { th in CGPoint(x: R * sin(th), y: top + ry * cos(th) - lip(th)) }

        // The body's outline: the sides, the front of the bottom, the back of the rim.
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -R, y: top - lip(-.pi / 2)))
        body.addLine(to: CGPoint(x: -R, y: base))
        body.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 0, clockwise: true,
                    transform: CGAffineTransform(translationX: 0, y: base).scaledBy(x: R, y: ry))
        body.addLine(to: CGPoint(x: R, y: top - lip(.pi / 2)))
        for i in 0...40 { body.addLine(to: rimPoint(.pi / 2 + .pi * CGFloat(i) / 40)) }
        body.closeSubpath()

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

    /// The flame standing on (0, 0), y down: a soft orange glow, the flame
    /// itself, a white core and a little blue at the base, each softened
    /// with a blur once, when the picture is made.
    private static func flamePicture(u: CGFloat, style st: CandleStyle, scale: CGFloat) -> (rect: CGRect, image: CGImage?) {
        let w = st.warmth
        let h = u * 1.7, fw = u * 0.36
        let pad = u * 0.9
        let rect = CGRect(x: -fw * 1.6 - pad, y: -h * 1.1 - pad, width: (fw * 1.6 + pad) * 2, height: h * 1.1 + u * 0.4 + pad * 2)
        func shape(_ ww: CGFloat, _ hh: CGFloat, dy: CGFloat = 0) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: dy + ww * 0.25))
            p.addCurve(to: CGPoint(x: 0, y: dy - hh), control1: CGPoint(x: -ww * 1.1, y: dy - hh * 0.02), control2: CGPoint(x: -ww * 0.85, y: dy - hh * 0.58))
            p.addCurve(to: CGPoint(x: 0, y: dy + ww * 0.25), control1: CGPoint(x: ww * 0.85, y: dy - hh * 0.58), control2: CGPoint(x: ww * 1.1, y: dy - hh * 0.02))
            p.closeSubpath()
            return p
        }
        func layer(_ blur: CGFloat, _ body: @escaping (CGContext) -> Void) -> CGImage? {
            guard let image = Sprite.draw(rect, scale: scale, body) else { return nil }
            return Sprite.blurred(image, radius: blur * scale)
        }
        let glow = layer(max(0.6, u * 0.22)) { ctx in
            Sprite.fill(ctx, shape(fw * 1.35, h * 1.08), hslColor(w - 6, 1, 0.55, 0.35))
        }
        let main = layer(max(0.3, u * 0.05)) { ctx in
            Sprite.clipped(ctx, shape(fw, h)) {
                Sprite.linear(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: -h), [
                    (0, hslColor(w + 10, 1, 0.8, 0.95)), (0.35, hslColor(w + 6, 1, 0.66, 0.95)),
                    (0.8, hslColor(w - 6, 1, 0.55, 0.8)), (1, hslColor(w - 14, 1, 0.5, 0.2)),
                ])
            }
        }
        let core = layer(max(0.3, u * 0.07)) { ctx in
            Sprite.clipped(ctx, shape(fw * 0.55, h * 0.62, dy: -u * 0.05)) {
                Sprite.linear(ctx, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: -h * 0.62), [
                    (0, Sprite.rgba(255, 255, 252, 1)), (1, Sprite.rgba(255, 248, 220, 0.55)),
                ])
            }
        }
        let blue = layer(max(0.3, u * 0.06)) { ctx in
            Sprite.fill(ctx, Sprite.ellipse(0, u * 0.02, fw * 0.55, u * 0.14), Sprite.rgba(80, 130, 255, 0.5))
        }
        let size = CGSize(width: (rect.width * scale).rounded(.up), height: (rect.height * scale).rounded(.up))
        return (rect, Sprite.stack([glow, main, core, blue], size: size))
    }

    // MARK: Motion

    /// The flame sways from its base on a slow loop of its own, and on the
    /// candle's flicker it stretches taller and burns brighter, together,
    /// as a real flame does; its halo follows the same flicker.
    private func flame(_ pic: (rect: CGRect, image: CGImage?), at tip: CGPoint, style st: CandleStyle,
                       seed: Int, flicker: Flicker) -> CALayer {
        let sway = CALayer()
        sway.bounds = CGRect(origin: .zero, size: pic.rect.size)
        sway.anchorPoint = CGPoint(x: -pic.rect.minX / pic.rect.width, y: pic.rect.maxY / pic.rect.height)
        sway.position = tip
        let stretch = Sprite.layer(pic.image, rect: pic.rect, at: CGPoint(x: -pic.rect.minX, y: pic.rect.maxY), scale: scale)
        sway.addSublayer(stretch)

        let f = Double(st.flicker)
        guard f > 0.01 else { return sway }
        var r = SeededRandom(seed: seed * 13 + 5)
        sway.add(loop("transform.rotation.z", around: 0, by: 0.1 * f, duration: 2.3 + Double(seed) * 0.37, random: &r), forKey: "sway")
        stretch.add(flicker.animation("transform.scale.y", around: 1, by: 0.12 * f), forKey: "stretch")
        stretch.add(flicker.animation("opacity", around: 0.92, by: 0.08 * f), forKey: "glow")
        return sway
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
