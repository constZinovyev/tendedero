import AppKit
import QuartzCore

/// Everything about how a garland looks, in one place. The values match the
/// sliders of the design mockup, so a look tuned there drops straight in.
struct GarlandStyle {
    /// Strands twisted together into the wire.
    var strands = 2
    var wireWidth: CGFloat = 1.2
    /// Length of one full twist of the strands.
    var twistPitch: CGFloat = 18
    /// Bulb radius (its height; it is a little narrower than tall).
    var bulbSize: CGFloat = 3.5
    /// How far below the wire a bulb hangs on its own short lead.
    var drop: CGFloat = 4
    var glowRadius: CGFloat = 16
    /// Hue of the light in degrees: lower is more orange, higher more yellow.
    var warmth: CGFloat = 40

    static var current = GarlandStyle()

    func light(_ alpha: CGFloat, saturation: CGFloat = 1, brightness: CGFloat = 1) -> CGColor {
        NSColor(hue: warmth / 360, saturation: saturation, brightness: brightness, alpha: alpha).cgColor
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
    func render(_ garlands: [Garland], origin: CGPoint, scale: CGFloat, style: GarlandStyle = .current) {
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

        // The wire: strands twisted around the curve.
        let amplitude = style.strands > 1 ? style.wireWidth * 0.9 : 0
        for k in 0..<max(1, style.strands) {
            let path = CGMutablePath()
            for (i, p) in local.enumerated() {
                let n = geo.normal(at: i)
                let o = amplitude * sin(2 * .pi * geo.lengths[i] / style.twistPitch + CGFloat(k) * 2 * .pi / CGFloat(style.strands))
                let q = CGPoint(x: p.x + n.dx * o, y: p.y + n.dy * o)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            let strand = CAShapeLayer()
            strand.path = path
            strand.fillColor = nil
            strand.strokeColor = NSColor(white: 0.04, alpha: 1).cgColor
            strand.lineWidth = style.wireWidth
            strand.lineCap = .round
            strand.contentsScale = scale
            container.addSublayer(strand)

            let sheen = CAShapeLayer()
            sheen.path = path
            sheen.fillColor = nil
            sheen.strokeColor = NSColor(white: 1, alpha: 0.12).cgColor
            sheen.lineWidth = max(0.3, style.wireWidth * 0.3)
            sheen.contentsScale = scale
            container.addSublayer(sheen)
        }

        // The bulbs.
        let positions = geo.bulbPositions(spacing: g.spacing).map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        for (i, p) in positions.enumerated() {
            let bulb = self.bulb(at: p, style: style)
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

    /// A bulb: its lead, the dark glass you see when it is off, and over it
    /// a lit group (glow, warm glass, bright core) whose opacity is the light.
    private func bulb(at p: CGPoint, style: GarlandStyle) -> (base: CALayer, lit: CALayer) {
        let base = CALayer()
        let center = CGPoint(x: p.x, y: p.y - style.drop)
        let w = style.bulbSize * 1.5, h = style.bulbSize * 2

        if style.drop > 0 {
            let lead = CAShapeLayer()
            let path = CGMutablePath()
            path.move(to: p)
            path.addLine(to: center)
            lead.path = path
            lead.strokeColor = NSColor(white: 0.04, alpha: 1).cgColor
            lead.lineWidth = max(0.6, style.wireWidth * 0.6)
            lead.contentsScale = scale
            base.addSublayer(lead)
        }

        let glass = CALayer()
        glass.frame = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        glass.cornerRadius = w / 2
        glass.backgroundColor = style.light(1, saturation: 0.35, brightness: 0.22)
        base.addSublayer(glass)

        let lit = CALayer()
        if style.glowRadius > 0 {
            let r = style.glowRadius + style.bulbSize
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.frame = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            glow.colors = [style.light(0.55), style.light(0.22, brightness: 0.95), style.light(0)]
            glow.locations = [0, 0.35, 1]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            lit.addSublayer(glow)
        }
        let warm = CALayer()
        warm.frame = glass.frame
        warm.cornerRadius = w / 2
        warm.backgroundColor = style.light(1, saturation: 0.95, brightness: 0.95)
        lit.addSublayer(warm)
        let core = CALayer()
        let cw = w * 0.47, ch = h * 0.5
        core.frame = CGRect(x: center.x - cw / 2, y: center.y - ch / 2 + style.bulbSize * 0.15, width: cw, height: ch)
        core.cornerRadius = cw / 2
        core.backgroundColor = NSColor(hue: (style.warmth + 10) / 360, saturation: 0.35, brightness: 1, alpha: 1).cgColor
        lit.addSublayer(core)

        base.addSublayer(lit)
        return (base, lit)
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
