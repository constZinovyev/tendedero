import AppKit
import QuartzCore

/// Three candles standing on the desktop: the left one the shortest, the
/// middle one the tallest, the right one a little shorter than the middle.
/// Like the garlands, they live under every window and only take the mouse
/// while you are editing.
struct CandleSet: Codable, Equatable {
    /// Where the middle candle stands, in global screen coordinates: the
    /// bottom of its wax, on top of its saucer.
    var position: CGPoint

    /// Heights of the left, middle and right candles, as parts of the tallest.
    static let heights: [CGFloat] = [0.62, 1, 0.82]
}

/// How the candles look, set from the Candles appearance menu and saved.
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
            case .cream: (44, 0.52, 0.88)
            case .white: (40, 0.12, 0.95)
            case .ivory: (48, 0.40, 0.91)
            case .honey: (36, 0.75, 0.62)
            }
        }
    }

    var wax: Wax = .cream
    /// The unit everything is drawn in, in points. A candle is about seven
    /// units tall at full height.
    var size: CGFloat = 11
    /// The halo of light around each flame, 0 to 1.5.
    var halo: CGFloat = 0.9
    /// How much the flames move and flicker, 0 to 1.5.
    var flicker: CGFloat = 0.7
    /// Hue of the light in degrees.
    var warmth: CGFloat = 32

    static let defaults = CandleStyle()

    var bodyWidth: CGFloat { size * 3.1 }
    /// Distance between the candles' centres.
    var gap: CGFloat { size * 5.6 }

    /// The space the three candles take, flames and saucers included, for
    /// a set standing at `position`. Used for clicking on them while editing.
    func bounds(at position: CGPoint) -> CGRect {
        let halfWidth = gap + bodyWidth * 0.8
        let top = position.y + size * 7 + size * 2.2
        let bottom = position.y - size * 1.1
        return CGRect(x: position.x - halfWidth, y: bottom, width: halfWidth * 2, height: top - bottom)
    }
}

/// HSL to a color, as the design pages specify colors.
func hslColor(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) -> CGColor {
    let l = min(max(l, 0), 1)
    let v = l + s * min(l, 1 - l)
    let sv = v == 0 ? 0 : 2 * (1 - l / v)
    var hue = h.truncatingRemainder(dividingBy: 360)
    if hue < 0 { hue += 360 }
    return NSColor(hue: hue / 360, saturation: sv, brightness: v, alpha: min(max(a, 0), 1)).cgColor
}

/// Draws the candles with Core Animation. The flicker is a set of slow,
/// uneven keyframe loops on each flame (stretch, sway, glow) running on the
/// GPU, so it looks alive without the app doing any work per frame.
@MainActor
final class CandleLayers {
    let root = CALayer()
    private var scale: CGFloat = 2

    func render(_ set: CandleSet?, style: CandleStyle, origin: CGPoint, scale: CGFloat) {
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        if let set {
            let base = CGPoint(x: set.position.x - origin.x, y: set.position.y - origin.y)
            let xs = [-style.gap, 0, style.gap].map { base.x + $0 }
            // Halos first so the wax stays visible through them.
            var halos: [CALayer] = []
            for (i, x) in xs.enumerated() {
                root.addSublayer(saucer(x: x, base: base.y, style: style))
                let top = base.y + style.size * 7 * CandleSet.heights[i]
                halos.append(halo(at: CGPoint(x: x, y: top + style.size * 0.75), style: style, seed: i))
            }
            halos.forEach { root.insertSublayer($0, at: 0) }
            for (i, x) in xs.enumerated() {
                candle(x: x, base: base.y, height: CandleSet.heights[i], style: style, seed: i)
            }
        }
        CATransaction.commit()
    }

    // MARK: Parts

    private func wax(_ st: CandleStyle, _ dl: CGFloat, _ a: CGFloat = 1) -> CGColor {
        let (h, s, l) = st.wax.hsl
        return hslColor(h, s, l + dl / 100, a)
    }

    /// A small ceramic saucer under each candle.
    private func saucer(x: CGFloat, base: CGFloat, style st: CandleStyle) -> CALayer {
        let u = st.size, r = st.bodyWidth * 0.78
        let group = CALayer()
        let plate = CAShapeLayer()
        plate.path = CGPath(ellipseIn: CGRect(x: x - r, y: base - u * 0.35 - u * 0.55, width: r * 2, height: u * 1.1), transform: nil)
        plate.fillColor = NSColor(red: 0.94, green: 0.92, blue: 0.89, alpha: 1).cgColor
        plate.strokeColor = NSColor(white: 0, alpha: 0.18).cgColor
        plate.lineWidth = 1
        group.addSublayer(plate)
        let well = CAShapeLayer()
        let wr = r * 0.8
        well.path = CGPath(ellipseIn: CGRect(x: x - wr, y: base - u * 0.18 - u * 0.36, width: wr * 2, height: u * 0.72), transform: nil)
        well.fillColor = NSColor(red: 0.89, green: 0.87, blue: 0.83, alpha: 1).cgColor
        group.addSublayer(well)
        return group
    }

    /// A pillar candle: shaded wax, a warm glow near the top where the flame
    /// lights the wax, a few drips, a melted pool, the wick and the flame.
    private func candle(x: CGFloat, base: CGFloat, height k: CGFloat, style st: CandleStyle, seed: Int) {
        let u = st.size, w = st.bodyWidth, h = u * 7 * k
        let top = base + h

        let body = CAGradientLayer()
        body.frame = CGRect(x: x - w / 2, y: base, width: w, height: h)
        body.colors = [wax(st, -22), wax(st, -4), wax(st, 3), wax(st, -6), wax(st, -26)]
        body.locations = [0, 0.25, 0.5, 0.78, 1]
        body.startPoint = CGPoint(x: 0, y: 0.5)
        body.endPoint = CGPoint(x: 1, y: 0.5)
        root.addSublayer(body)

        let glowH = min(h, w * 1.2)
        let lit = CAGradientLayer()
        lit.frame = CGRect(x: x - w / 2, y: top - glowH, width: w, height: glowH)
        lit.colors = [hslColor(st.warmth + 6, 1, 0.72, 0.55), hslColor(st.warmth, 1, 0.6, 0)]
        lit.startPoint = CGPoint(x: 0.5, y: 1)
        lit.endPoint = CGPoint(x: 0.5, y: 0)
        root.addSublayer(lit)

        // Drips down from the rim.
        var r = SeededRandom(seed: seed * 7 + 3)
        let drips = CGMutablePath()
        for _ in 0..<3 {
            let dx = (r.nextCG() - 0.5) * w * 0.8
            let len = u * (0.6 + r.nextCG() * 1.6)
            let dw = u * (0.18 + r.nextCG() * 0.12)
            drips.move(to: CGPoint(x: x + dx - dw, y: top))
            drips.addLine(to: CGPoint(x: x + dx - dw * 0.8, y: top - len))
            drips.addArc(center: CGPoint(x: x + dx, y: top - len), radius: dw * 0.8, startAngle: .pi, endAngle: 0, clockwise: false)
            drips.addLine(to: CGPoint(x: x + dx + dw, y: top))
            drips.closeSubpath()
        }
        root.addSublayer(fill(drips, wax(st, 4, 0.9)))

        // The top, the melted pool and the soft rim.
        let topRect = CGRect(x: x - w / 2, y: top - u * 0.42, width: w, height: u * 0.84)
        root.addSublayer(fill(CGPath(ellipseIn: topRect, transform: nil), wax(st, -2)))
        let pool = CAGradientLayer()
        pool.type = .radial
        pool.frame = CGRect(x: x - w * 0.36, y: top - u * 0.06 - u * 0.27, width: w * 0.72, height: u * 0.54)
        pool.colors = [hslColor(st.warmth + 8, 1, 0.82, 0.95), hslColor(st.warmth, 0.8, 0.7, 0.55)]
        pool.startPoint = CGPoint(x: 0.5, y: 0.5)
        pool.endPoint = CGPoint(x: 1, y: 1)
        let poolMask = CAShapeLayer()
        poolMask.path = CGPath(ellipseIn: CGRect(origin: .zero, size: pool.frame.size), transform: nil)
        pool.mask = poolMask
        root.addSublayer(pool)
        let rim = CAShapeLayer()
        rim.path = CGPath(ellipseIn: topRect, transform: nil)
        rim.fillColor = nil
        rim.strokeColor = wax(st, 8, 0.6)
        rim.lineWidth = max(1, u * 0.1)
        root.addSublayer(rim)

        // The wick and the flame on it.
        let tip = CGPoint(x: x, y: top + u * 0.05)
        let wick = CGMutablePath()
        wick.move(to: CGPoint(x: x, y: tip.y - u * 0.18))
        wick.addQuadCurve(to: CGPoint(x: x, y: tip.y + u * 0.12), control: CGPoint(x: x + u * 0.02, y: tip.y))
        let wickLayer = CAShapeLayer()
        wickLayer.path = wick
        wickLayer.fillColor = nil
        wickLayer.strokeColor = NSColor(red: 0.1, green: 0.08, blue: 0.06, alpha: 1).cgColor
        wickLayer.lineWidth = max(1, u * 0.07)
        wickLayer.lineCap = .round
        root.addSublayer(wickLayer)
        root.addSublayer(flame(at: tip, style: st, seed: seed))
    }

    /// The flame: an outer warm teardrop, a white core and a little blue at
    /// the base. It stretches and sways around its base on uneven loops.
    private func flame(at tip: CGPoint, style st: CandleStyle, seed: Int) -> CALayer {
        let u = st.size
        let H = u * 1.55, w = u * 0.42
        let size = CGSize(width: w * 2.6, height: H + u * 0.3)
        let ox = size.width / 2, oy = u * 0.1
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x, y: oy + y) }

        // Sway on the outer layer, stretch on the inner one, so the two
        // loops run independently.
        let sway = CALayer()
        sway.bounds = CGRect(origin: .zero, size: size)
        sway.anchorPoint = CGPoint(x: 0.5, y: oy / size.height)
        sway.position = tip
        let stretch = CALayer()
        stretch.bounds = sway.bounds
        stretch.anchorPoint = sway.anchorPoint
        stretch.position = CGPoint(x: ox, y: oy)
        sway.addSublayer(stretch)

        let outer = CGMutablePath()
        outer.move(to: p(0, -u * 0.08))
        outer.addCurve(to: p(0, H), control1: p(-w * 1.05, H * 0.05), control2: p(-w * 0.9, H * 0.55))
        outer.addCurve(to: p(0, -u * 0.08), control1: p(w * 0.9, H * 0.55), control2: p(w * 1.05, H * 0.05))
        let body = CAGradientLayer()
        body.type = .radial
        body.frame = stretch.bounds
        let c = CGPoint(x: ox / size.width, y: (oy + H * 0.3) / size.height)
        body.startPoint = c
        body.endPoint = CGPoint(x: c.x + H * 0.8 / size.width, y: c.y + H * 0.8 / size.height)
        body.colors = [hslColor(st.warmth + 14, 1, 0.92, 0.95),
                       hslColor(st.warmth + 4, 1, 0.64, 0.85),
                       hslColor(st.warmth - 12, 1, 0.5, 0.25)]
        body.locations = [0, 0.45, 1]
        let bodyMask = CAShapeLayer()
        bodyMask.path = outer
        body.mask = bodyMask
        stretch.addSublayer(body)

        let inner = CGMutablePath()
        inner.move(to: p(0, 0))
        inner.addCurve(to: p(0, H * 0.66), control1: p(-w * 0.5, H * 0.1), control2: p(-w * 0.4, H * 0.42))
        inner.addCurve(to: p(0, 0), control1: p(w * 0.4, H * 0.42), control2: p(w * 0.5, H * 0.1))
        let core = CAGradientLayer()
        core.frame = stretch.bounds
        core.colors = [NSColor(red: 1, green: 1, blue: 0.98, alpha: 0.95).cgColor,
                       NSColor(red: 1, green: 0.98, blue: 0.88, alpha: 0.6).cgColor]
        core.startPoint = CGPoint(x: 0.5, y: oy / size.height)
        core.endPoint = CGPoint(x: 0.5, y: (oy + H * 0.66) / size.height)
        let coreMask = CAShapeLayer()
        coreMask.path = inner
        core.mask = coreMask
        stretch.addSublayer(core)

        let blue = CAShapeLayer()
        blue.path = CGPath(ellipseIn: CGRect(x: ox - w * 0.42, y: oy - u * 0.02 - u * 0.16, width: w * 0.84, height: u * 0.32), transform: nil)
        blue.fillColor = NSColor(red: 0.35, green: 0.55, blue: 1, alpha: 0.45).cgColor
        stretch.addSublayer(blue)

        let f = Double(st.flicker)
        if f > 0.01 {
            var r = SeededRandom(seed: seed * 13 + 5)
            sway.add(loop("transform.rotation.z", around: 0, by: 0.1 * f, duration: 2.3 + Double(seed) * 0.37, random: &r), forKey: "sway")
            stretch.add(loop("transform.scale.y", around: 1, by: 0.12 * f, duration: 1.7 + Double(seed) * 0.23, random: &r), forKey: "stretch")
        }
        return sway
    }

    /// The soft warm light around a flame. It breathes with the flicker.
    private func halo(at c: CGPoint, style st: CandleStyle, seed: Int) -> CALayer {
        let r = st.size * 7
        let k = st.halo
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        layer.colors = [hslColor(st.warmth + 4, 1, 0.68, 0.42 * k),
                        hslColor(st.warmth, 1, 0.6, 0.2 * k),
                        hslColor(st.warmth - 4, 0.95, 0.55, 0.06 * k),
                        hslColor(st.warmth - 6, 0.9, 0.5, 0)]
        layer.locations = [0, 0.2, 0.55, 1]
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        let f = Double(st.flicker)
        if f > 0.01 && k > 0.01 {
            var rand = SeededRandom(seed: seed * 29 + 11)
            layer.add(loop("opacity", around: 0.9, by: 0.1 * f, duration: 1.3 + Double(seed) * 0.29, random: &rand), forKey: "breathe")
        }
        return layer
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
        return a
    }

    private func fill(_ path: CGPath, _ color: CGColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = color
        layer.contentsScale = scale
        return layer
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
