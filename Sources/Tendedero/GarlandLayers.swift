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
            container.addSublayer(stroke(path, color: ink, width: style.wireWidth, cap: .round))
            container.addSublayer(stroke(path, color: NSColor(white: 1, alpha: 0.14).cgColor,
                                         width: max(0.3, style.wireWidth * 0.3)))
        }

        // The bulbs, each on its lead.
        let positions = geo.bulbPositions(spacing: g.spacing).map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        for (i, p) in positions.enumerated() {
            if style.lead > 0 {
                let path = CGMutablePath()
                path.move(to: p)
                path.addLine(to: CGPoint(x: p.x, y: p.y - style.lead))
                container.addSublayer(stroke(path, color: ink, width: max(0.6, style.wireWidth * 0.6)))
            }
            let attach = CGPoint(x: p.x, y: p.y - style.lead)
            let bulb: (base: CALayer, lit: CALayer)
            switch style.design {
            case .glass: bulb = glassBulb(at: attach, style: style)
            case .cartoon: bulb = cartoonBulb(at: attach, style: style)
            }
            container.addSublayer(bulb.base)
            bulb.lit.opacity = Float(g.brightness)
            if g.bulbsOff.contains(i) || g.mode == .off {
                bulb.lit.opacity = 0
            } else if let animation = animation(for: g, bulb: i, now: now) {
                bulb.lit.add(animation, forKey: "light")
            }
        }
        return container
    }

    // MARK: Designs

    /// Variant 2 of the design page: clear glass on a black cap, a filament
    /// on two supports, a highlight streak, and a halo around it. The glass,
    /// the dark filament and the highlight are always there; everything that
    /// glows sits in `lit`, whose opacity is the light.
    private func glassBulb(at p: CGPoint, style st: GarlandStyle) -> (base: CALayer, lit: CALayer) {
        let s = st.bulbSize
        let base = CALayer()
        let lit = CALayer()
        let gy = p.y - st.capHeight - s * 1.05        // the glass's reference point
        let center = CGPoint(x: p.x, y: gy - s * 0.12) // the filament
        let glassPath = Self.dropPath(x: p.x, y: gy, s: s)
        let milk = 1 - min(max(st.glassClarity, 0), 1)

        // Halo first, so it sits under the glass.
        if let halo = halo(at: center, style: st) { lit.addSublayer(halo) }

        // Glass: a faint tint you can see through.
        let glass = CAShapeLayer()
        glass.path = glassPath
        glass.fillColor = NSColor(white: 1, alpha: 0.12 + 0.4 * milk).cgColor
        glass.strokeColor = NSColor(white: 0.25, alpha: 0.35).cgColor
        glass.lineWidth = max(0.6, s * 0.07)
        glass.contentsScale = scale
        base.addSublayer(glass)

        // The cap.
        let cap = CALayer()
        let cw = s * 0.42
        cap.frame = CGRect(x: p.x - cw / 2, y: p.y - st.capHeight - 0.5, width: cw, height: st.capHeight + 0.5)
        cap.backgroundColor = NSColor(white: 0.05, alpha: 1).cgColor
        cap.cornerRadius = min(cw, st.capHeight) * 0.25
        cap.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        cap.borderWidth = 0.5
        base.addSublayer(cap)

        // Filament supports and the filament itself, dark when off.
        let supports = CGMutablePath()
        for dx in [-0.12 * s, 0.12 * s] {
            supports.move(to: CGPoint(x: center.x + dx, y: center.y + s * 0.3))
            supports.addLine(to: CGPoint(x: center.x + dx, y: center.y))
        }
        base.addSublayer(stroke(supports, color: NSColor(white: 0.4, alpha: 0.5).cgColor, width: max(0.4, s * 0.04)))
        let fw = s * 0.32, fh = max(1.2, s * 0.18)
        let filamentPath = CGPath(ellipseIn: CGRect(x: center.x - fw / 2, y: center.y - fh / 2, width: fw, height: fh), transform: nil)
        let darkFilament = CAShapeLayer()
        darkFilament.path = filamentPath
        darkFilament.fillColor = NSColor(white: 0.42, alpha: 0.7).cgColor
        base.addSublayer(darkFilament)

        // Light inside the glass: bright at the filament, warmer to the edge.
        let r = s * 1.15
        let inner = radial(center: center, radius: r,
                           colors: [st.light(0.95, hueShift: 8, lightness: 0.93),
                                    st.light(0.45 + 0.4 * milk, lightness: 0.72),
                                    st.light(0.12 + 0.45 * milk, hueShift: -4, saturation: 0.95, lightness: 0.55)],
                           locations: [0, 0.3, 1])
        inner.mask = mask(glassPath, in: inner.frame)
        lit.addSublayer(inner)

        // A warm rim where the lit glass catches the light.
        let rim = CAShapeLayer()
        rim.path = glassPath
        rim.fillColor = nil
        rim.strokeColor = st.light(0.6, lightness: 0.7)
        rim.lineWidth = max(0.6, s * 0.07)
        rim.contentsScale = scale
        lit.addSublayer(rim)

        // The hot filament and its small bloom.
        let hot = CAShapeLayer()
        hot.path = filamentPath
        hot.fillColor = st.light(1, hueShift: 15, lightness: 0.7 + 0.28 * st.filament)
        lit.addSublayer(hot)
        lit.addSublayer(radial(center: center, radius: s * 0.55,
                               colors: [NSColor(red: 1, green: 0.98, blue: 0.92, alpha: 0.85 * st.filament).cgColor,
                                        NSColor(red: 1, green: 0.94, blue: 0.82, alpha: 0).cgColor],
                               locations: [0, 1]))
        base.addSublayer(lit)

        // A highlight streak on the glass, over the light.
        let streak = CAShapeLayer()
        let hw = s * 0.22, hh = s * 0.84
        streak.path = CGPath(ellipseIn: CGRect(x: p.x - s * 0.32 - hw / 2, y: gy + s * 0.15 - hh / 2, width: hw, height: hh),
                             transform: nil)
        streak.fillColor = NSColor(white: 1, alpha: 0.45).cgColor
        let clip = CAShapeLayer()
        clip.path = glassPath
        let holder = CALayer()
        holder.addSublayer(streak)
        holder.mask = clip
        base.addSublayer(holder)

        return (base, lit)
    }

    /// Variant 1 of the design page: a flat warm drop with a strong halo.
    private func cartoonBulb(at p: CGPoint, style st: GarlandStyle) -> (base: CALayer, lit: CALayer) {
        let s = st.bulbSize
        let base = CALayer()
        let lit = CALayer()
        let center = CGPoint(x: p.x, y: p.y - s * 1.1)
        let body = CGRect(x: center.x - s * 0.75, y: center.y - s, width: s * 1.5, height: s * 2)

        if let halo = halo(at: center, style: st) { lit.addSublayer(halo) }
        let dark = CALayer()
        dark.frame = body
        dark.cornerRadius = s * 0.75
        dark.backgroundColor = st.light(1, saturation: 0.35, lightness: 0.25)
        base.addSublayer(dark)
        let warm = CALayer()
        warm.frame = body
        warm.cornerRadius = s * 0.75
        warm.backgroundColor = st.light(1, saturation: 0.95, lightness: 0.72)
        lit.addSublayer(warm)
        let core = CALayer()
        let cw = s * 0.7, ch = s
        core.frame = CGRect(x: center.x - cw / 2, y: center.y - ch / 2 + s * 0.15, width: cw, height: ch)
        core.cornerRadius = cw / 2
        core.backgroundColor = st.light(1, hueShift: 10, lightness: 0.92)
        lit.addSublayer(core)
        base.addSublayer(lit)
        return (base, lit)
    }

    /// The halo of warm light around a bulb, fading out softly.
    private func halo(at c: CGPoint, style st: GarlandStyle) -> CALayer? {
        let k = st.haloStrength
        guard k > 0.005, st.haloSize > 0 else { return nil }
        return radial(center: c, radius: st.bulbSize * st.haloSize + 6,
                      colors: [st.light(0.5 * k, saturation: 0.95, lightness: 0.66),
                               st.light(0.22 * k, saturation: 0.95, lightness: 0.6),
                               st.light(0.06 * k, saturation: 0.9, lightness: 0.55),
                               st.light(0, saturation: 0.9, lightness: 0.5)],
                      locations: [0, 0.22, 0.55, 1])
    }

    // MARK: Helpers

    private func radial(center c: CGPoint, radius r: CGFloat, colors: [CGColor], locations: [NSNumber]) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        layer.colors = colors
        layer.locations = locations
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 1)
        return layer
    }

    /// A mask shaped like `path`, for a layer whose frame is `frame`.
    private func mask(_ path: CGPath, in frame: CGRect) -> CAShapeLayer {
        let mask = CAShapeLayer()
        var t = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        mask.path = path.copy(using: &t)
        return mask
    }

    /// The glass outline of variant 2, narrow at the cap and round below,
    /// around a reference point; AppKit coordinates, so "down" is minus.
    private static func dropPath(x: CGFloat, y: CGFloat, s: CGFloat) -> CGPath {
        let w = s * 0.62, h = s * 1.05
        func pt(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y - dy) }
        let path = CGMutablePath()
        path.move(to: pt(-w * 0.45, -h))
        path.addCurve(to: pt(-w, h * 0.2), control1: pt(-w * 0.5, -h * 0.5), control2: pt(-w, -h * 0.3))
        path.addCurve(to: pt(w, h * 0.2), control1: pt(-w, h * 0.95), control2: pt(w, h * 0.95))
        path.addCurve(to: pt(w * 0.45, -h), control1: pt(w, -h * 0.3), control2: pt(w * 0.5, -h * 0.5))
        path.closeSubpath()
        return path
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
            return a
        }
    }
}
