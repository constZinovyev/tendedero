import AppKit
import QuartzCore

/// Everything about how the garlands look, in one place, set from the
/// Appearance menu and kept in the user defaults. The values match the
/// design page the looks were chosen on.
struct GarlandStyle: Codable, Equatable {
    enum Design: String, Codable, CaseIterable {
        /// A small clear glass bulb with a filament and a black cap.
        case glass
        /// A flat warm drop: the first sketch.
        case cartoon

        var title: String {
            switch self {
            case .glass: L("Glass mini bulb", "Bombilla de cristal")
            case .cartoon: L("Cartoon drop", "Gota dibujada")
            }
        }
    }

    var design: Design = .glass
    /// The bulb's scale: about its half height, in points.
    var bulbSize: CGFloat = 4
    /// How clear the glass is: 1 lets the background through, 0 is milky.
    var glassClarity: CGFloat = 0.7
    /// How hot the filament glows, 0 to 1.
    var filament: CGFloat = 0.6
    /// The halo of light around each bulb, as a multiple of the bulb's size.
    var haloSize: CGFloat = 4.5
    /// How strong the halo is, 0 to 1.5.
    var haloStrength: CGFloat = 1.35
    /// Hue of the light in degrees: lower is more orange, higher more yellow.
    var warmth: CGFloat = 36

    /// Strands twisted together into the wire.
    var strands = 2
    var wireWidth: CGFloat = 1.1
    /// Length of one full twist of the strands.
    var twistPitch: CGFloat = 16
    /// The short lead each bulb hangs from, below the wire.
    var lead: CGFloat = 3

    static let defaults = GarlandStyle()

    /// A warm color of the garland's hue, given in HSL like the design page.
    func light(_ alpha: CGFloat, hueShift: CGFloat = 0, saturation: CGFloat = 1, lightness: CGFloat = 0.6) -> CGColor {
        let l = min(max(lightness, 0), 1), s = saturation
        let v = l + s * min(l, 1 - l)
        let sv = v == 0 ? 0 : 2 * (1 - l / v)
        var h = (warmth + hueShift).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return NSColor(hue: h / 360, saturation: sv, brightness: v, alpha: min(max(alpha, 0), 1)).cgColor
    }

    /// The black cap the glass sits in.
    var capHeight: CGFloat { bulbSize * 0.38 }

    /// How far below the point it hangs from the bulb's light is.
    var lightDrop: CGFloat {
        switch design {
        case .glass: lead + capHeight + bulbSize * 1.17
        case .cartoon: lead + bulbSize * 1.1
        }
    }

    /// The middle of a bulb hanging from a point on the wire, in AppKit
    /// coordinates (y up). Used for drawing and for clicking on a bulb.
    func bulbCenter(below wirePoint: CGPoint) -> CGPoint {
        CGPoint(x: wirePoint.x, y: wirePoint.y - lightDrop)
    }
}

/// Draws garlands with Core Animation layers. The motion of blinking and of
/// the wave is handed to Core Animation as repeating keyframes, so it runs
/// on the GPU and the app does no work per frame.
@MainActor
final class GarlandLayers {
    let root = CALayer()
    private var scale: CGFloat = 2

    init() {
        root.masksToBounds = false
    }

    /// Rebuilds every garland. `origin` is the screen's origin in global
    /// coordinates, so a garland is drawn where it belongs on this screen.
    func render(_ garlands: [Garland], style: GarlandStyle, origin: CGPoint, scale: CGFloat) {
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        // One shared start time keeps every blinking garland in step.
        let now = CACurrentMediaTime()
        for g in garlands {
            root.addSublayer(layer(for: g, origin: origin, style: style, now: now))
        }
        CATransaction.commit()
    }

    private func layer(for g: Garland, origin: CGPoint, style: GarlandStyle, now: CFTimeInterval) -> CALayer {
        let container = CALayer()
        let fixed = CALayer()
        let light = CALayer()
        let bulbs = bulbSprites(style)
        let geo = GarlandGeometry(g)
        let local = geo.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        let ink = NSColor(white: 0.045, alpha: 1).cgColor

        // The wire: strands twisted around the curve.
        let strands = max(1, style.strands)
        let amplitude = strands > 1 ? style.wireWidth * 0.9 : 0
        for k in 0..<strands {
            let path = CGMutablePath()
            for (i, p) in local.enumerated() {
                let n = geo.normal(at: i)
                let o = amplitude * sin(2 * .pi * geo.lengths[i] / max(style.twistPitch, 2) + CGFloat(k) * 2 * .pi / CGFloat(strands))
                let q = CGPoint(x: p.x + n.dx * o, y: p.y + n.dy * o)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            fixed.addSublayer(stroke(path, color: ink, width: style.wireWidth, cap: .round))
            fixed.addSublayer(stroke(path, color: NSColor(white: 1, alpha: 0.14).cgColor,
                                         width: max(0.3, style.wireWidth * 0.3)))
        }

        // The bulbs, each on its lead.
        let positions = geo.bulbPositions(spacing: g.spacing).map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        for (i, p) in positions.enumerated() {
            if style.lead > 0 {
                let path = CGMutablePath()
                path.move(to: p)
                path.addLine(to: CGPoint(x: p.x, y: p.y - style.lead))
                fixed.addSublayer(stroke(path, color: ink, width: max(0.6, style.wireWidth * 0.6)))
            }
            let attach = CGPoint(x: p.x, y: p.y - style.lead)
            fixed.addSublayer(Sprite.layer(bulbs.off, rect: bulbs.rect, at: attach, scale: scale))
            let lit = Sprite.layer(bulbs.on, rect: bulbs.rect, at: attach, scale: scale)
            lit.opacity = Float(g.brightness)
            if g.bulbsOff.contains(i) || g.mode == .off {
                continue
            } else if let animation = animation(for: g, bulb: i, now: now) {
                lit.add(animation, forKey: "light")
            }
            light.addSublayer(lit)
        }
        // Everything that never changes is cached as one bitmap; only the
        // lit bulbs above it are composited when they fade.
        fixed.shouldRasterize = true
        fixed.rasterizationScale = scale
        container.addSublayer(fixed)
        container.addSublayer(light)
        return container
    }

    // MARK: Bulb sprites

    /// The two pictures of a bulb for the current style: dark and lit. They
    /// are drawn once and shared by every bulb of every garland; a bulb is
    /// then just two image layers, and its light is the lit one's opacity.
    private struct BulbSprites {
        let style: GarlandStyle
        let scale: CGFloat
        /// The sprite's rect around the point the bulb hangs from, y down.
        let rect: CGRect
        let off: CGImage?
        let on: CGImage?
    }
    private var sprites: BulbSprites?

    private func bulbSprites(_ st: GarlandStyle) -> BulbSprites {
        if let sprites, sprites.style == st, sprites.scale == scale { return sprites }
        let s = st.bulbSize
        let center = st.lightDrop - st.lead
        let r = max(s * st.haloSize + 6, s * 1.6)
        let rect = CGRect(x: -r, y: min(0, center - r) - 2, width: r * 2, height: max(center + r, s * 3) + 2 - min(0, center - r) + 2)
        let draw: (CGContext, CGFloat) -> Void = { ctx, a in
            switch st.design {
            case .glass: Self.drawGlass(ctx, s: s, a: a, style: st)
            case .cartoon: Self.drawCartoon(ctx, s: s, a: a, style: st)
            }
        }
        let made = BulbSprites(style: st, scale: scale, rect: rect,
                               off: Sprite.draw(rect, scale: scale) { draw($0, 0) },
                               on: Sprite.draw(rect, scale: scale) { draw($0, 1) })
        sprites = made
        return made
    }

    /// The halo, as on the design page: a soft warm glow around the light.
    private static func drawHalo(_ ctx: CGContext, x: CGFloat, y: CGFloat, r: CGFloat, k: CGFloat, warmth w: CGFloat) {
        guard k > 0.005, r > 0 else { return }
        let m: CGFloat = 0.85
        Sprite.radial(ctx, center: CGPoint(x: x, y: y), radius: r, [
            (0, hslColor(w, 0.95, 0.66, 0.5 * k * m)),
            (0.22, hslColor(w, 0.95, 0.6, 0.22 * k * m)),
            (0.55, hslColor(w, 0.9, 0.55, 0.06 * k * m)),
            (1, hslColor(w, 0.9, 0.5, 0)),
        ])
    }

    /// The glass outline: narrow at the cap, round below. y down.
    private static func dropPath(x: CGFloat, y: CGFloat, s: CGFloat) -> CGPath {
        let w = s * 0.62, h = s * 1.05
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x - w * 0.45, y: y - h))
        p.addCurve(to: CGPoint(x: x - w, y: y + h * 0.2), control1: CGPoint(x: x - w * 0.5, y: y - h * 0.5), control2: CGPoint(x: x - w, y: y - h * 0.3))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.2), control1: CGPoint(x: x - w, y: y + h * 0.95), control2: CGPoint(x: x + w, y: y + h * 0.95))
        p.addCurve(to: CGPoint(x: x + w * 0.45, y: y - h), control1: CGPoint(x: x + w, y: y - h * 0.3), control2: CGPoint(x: x + w * 0.5, y: y - h * 0.5))
        p.closeSubpath()
        return p
    }

    /// Variant 2 of the design page: clear glass on a black cap, a filament
    /// on two supports, a highlight streak, and a halo. `a` is the light,
    /// 0 or 1. Drawn hanging from (0, 0), y down.
    private static func drawGlass(_ ctx: CGContext, s: CGFloat, a: CGFloat, style st: GarlandStyle) {
        let x: CGFloat = 0, w = st.warmth
        let capW = s * 0.42, capH = st.capHeight
        let gy = capH + s * 1.05, cy = gy + s * 0.12
        let gl = 1 - min(max(st.glassClarity, 0), 1)
        let glass = dropPath(x: x, y: gy, s: s)

        if a > 0 { drawHalo(ctx, x: x, y: cy, r: s * st.haloSize + 6, k: st.haloStrength * a, warmth: w) }

        // Cap.
        let cap = CGPath(roundedRect: CGRect(x: x - capW / 2, y: 0, width: capW, height: capH),
                         cornerWidth: min(capW, capH) * 0.25, cornerHeight: min(capW, capH) * 0.25, transform: nil)
        Sprite.fill(ctx, cap, Sprite.rgba(13, 13, 15, 1))
        Sprite.stroke(ctx, cap, Sprite.rgba(255, 255, 255, 0.12), width: 0.6)

        // Glass body and the light inside it.
        Sprite.fill(ctx, glass, Sprite.rgba(255, 255, 255, 0.18 + 0.35 * gl))
        if a > 0 {
            Sprite.clipped(ctx, glass) {
                Sprite.radial(ctx, center: CGPoint(x: x, y: cy), radius: s * 1.15, [
                    (0, hslColor(w + 8, 1, 0.93, 0.95 * a)),
                    (0.3, hslColor(w, 1, 0.72, (0.45 + 0.4 * gl) * a)),
                    (1, hslColor(w - 4, 0.95, 0.55, (0.12 + 0.45 * gl) * a)),
                ])
            }
        }
        Sprite.stroke(ctx, glass, a > 0 ? hslColor(w, 1, 0.68, 0.25 + 0.45 * a) : Sprite.rgba(70, 65, 60, 0.4),
                      width: max(0.6, s * 0.07))

        // Filament on its supports, and its bloom when lit.
        let supports = CGMutablePath()
        for dx in [-0.12 * s, 0.12 * s] {
            supports.move(to: CGPoint(x: x + dx, y: cy - s * 0.3))
            supports.addLine(to: CGPoint(x: x + dx, y: cy))
        }
        Sprite.stroke(ctx, supports, Sprite.rgba(110, 110, 115, 0.5), width: max(0.4, s * 0.04), cap: .butt)
        let filament = Sprite.ellipse(x, cy, s * 0.16, max(0.6, s * 0.09))
        Sprite.fill(ctx, filament, a > 0 ? hslColor(w + 15, 1, 0.7 + 0.28 * st.filament, 0.5 + 0.5 * a)
                                         : Sprite.rgba(120, 110, 100, 0.7))
        if a > 0 {
            Sprite.radial(ctx, center: CGPoint(x: x, y: cy), radius: s * 0.55, [
                (0, Sprite.rgba(255, 250, 235, 0.85 * a * st.filament)),
                (1, Sprite.rgba(255, 240, 210, 0)),
            ])
        }

        // Highlight streak on the glass.
        Sprite.clipped(ctx, glass) {
            Sprite.fill(ctx, Sprite.ellipse(x - s * 0.32, gy - s * 0.15, s * 0.11, s * 0.42, rotation: -0.2),
                        Sprite.rgba(255, 255, 255, 0.35 + 0.25 * (1 - a)))
        }
    }

    /// Variant 1 of the design page: a flat warm drop with a strong halo.
    private static func drawCartoon(_ ctx: CGContext, s: CGFloat, a: CGFloat, style st: GarlandStyle) {
        let x: CGFloat = 0, cy = s * 1.1, w = st.warmth
        if a > 0 { drawHalo(ctx, x: x, y: cy, r: s * st.haloSize + 6, k: st.haloStrength * a, warmth: w) }
        Sprite.fill(ctx, Sprite.ellipse(x, cy, s * 0.75, s), hslColor(w, 0.35 + 0.6 * a, 0.3 + 0.52 * a))
        if a > 0 {
            Sprite.fill(ctx, Sprite.ellipse(x, cy - s * 0.15, s * 0.35, s * 0.5), hslColor(w + 10, 1, 0.92, a))
        } else {
            Sprite.fill(ctx, Sprite.ellipse(x - s * 0.25, cy - s * 0.35, s * 0.18, s * 0.28, rotation: -0.2),
                        Sprite.rgba(255, 255, 255, 0.35))
        }
    }

    private func stroke(_ path: CGPath, color: CGColor, width: CGFloat, cap: CAShapeLayerLineCap = .butt) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.path = path
        layer.fillColor = nil
        layer.strokeColor = color
        layer.lineWidth = width
        layer.lineCap = cap
        layer.contentsScale = scale
        return layer
    }

    /// The repeating light of a blinking or waving garland, scaled by its
    /// brightness. Every bulb starts from the same moment; the wave offsets
    /// each one by its lag behind the previous bulb.
    private func animation(for g: Garland, bulb i: Int, now: CFTimeInterval) -> CAAnimation? {
        let b = g.brightness
        switch g.mode {
        case .on, .off:
            return nil
        case .blink:
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = GarlandLight.blinkValues.map { $0 * b }
            a.keyTimes = GarlandLight.blinkTimes.map { NSNumber(value: $0) }
            a.duration = GarlandLight.blinkPeriod / g.speed
            a.repeatCount = .infinity
            a.beginTime = now
            a.isRemovedOnCompletion = false
            a.calm()
            return a
        case .wave:
            let period = 2 * .pi / (GarlandLight.waveRate * g.speed)
            let steps = 24
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = (0...steps).map { GarlandLight.wave(phase: 2 * .pi * Double($0) / Double(steps)) * b }
            a.calculationMode = .linear
            a.duration = period
            a.repeatCount = .infinity
            a.beginTime = now
            // Bulb i lags by i * waveLag radians of the cycle.
            let lag = Double(i) * GarlandLight.waveLag / (2 * .pi) * period
            a.timeOffset = period - lag.truncatingRemainder(dividingBy: period)
            a.isRemovedOnCompletion = false
            a.calm()
            return a
        }
    }
}
