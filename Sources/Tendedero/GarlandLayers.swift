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

    /// Each bulb on screen, so the air from the pointer can swing it.
    private var swings: [BulbSwing] = []
    /// The cached groups of dark and lit bulbs. Flattened while still,
    /// taken apart only while bulbs swing.
    private var groups: [CALayer] = []
    private var reach: CGFloat = 80
    private var flattenTimer: Timer?
    /// The wire and the bulbs on it, so a bird sitting on it can bend it.
    private var wire: Wire?
    /// Fish hanging in place of some bulbs, by bulb, above everything else.
    private var fish: [Int: CALayer] = [:]
    private let fishLayer = CALayer()
    private var style = GarlandStyle.defaults

    private struct Wire {
        let points: [CGPoint]
        let normals: [CGVector]
        let lengths: [CGFloat]
        let amplitude: CGFloat
        let pitch: CGFloat
        /// Each strand: its dark stroke and its highlight.
        let strands: [(CAShapeLayer, CAShapeLayer)]
        let fixed: CALayer
        /// Each bulb's holders, where they hang at rest, and how far along
        /// the wire they are.
        let bulbs: [(holders: [CALayer], rest: CGPoint, along: CGFloat)]
        var bent = false
    }

    init() {
        root.masksToBounds = false
    }

    deinit {
        MainActor.assumeIsolated {
            flattenTimer?.invalidate()
            bounce?.invalidate()
        }
    }

    /// Rebuilds every garland. `origin` is the screen's origin in global
    /// coordinates, so a garland is drawn where it belongs on this screen.
    /// `size` is the area to draw in: cached parts are flattened to it.
    func render(_ garlands: [Garland], style: GarlandStyle, origin: CGPoint, size: CGSize, scale: CGFloat) {
        self.scale = scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        swings = []
        groups = []
        wire = nil
        fish = [:]
        fishLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        self.style = style
        reach = max(80, style.bulbSize * 14)
        // One shared start time keeps every blinking garland in step.
        let now = CACurrentMediaTime()
        for g in garlands {
            root.addSublayer(layer(for: g, origin: origin, style: style, now: now))
        }
        fishLayer.frame = root.bounds
        root.addSublayer(fishLayer)
        CATransaction.commit()
    }

    private func layer(for g: Garland, origin: CGPoint, style: GarlandStyle, now: CFTimeInterval) -> CALayer {
        // Cached layers are flattened within their bounds, so every
        // container spans the whole area.
        let container = CALayer()
        container.frame = root.bounds
        let fixed = CALayer()
        fixed.frame = root.bounds
        let light = CALayer()
        light.frame = root.bounds
        let bulbs = bulbSprites(style)
        let geo = GarlandGeometry(g)
        let local = geo.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        let ink = NSColor(white: 0.045, alpha: 1).cgColor

        // The wire: strands twisted around the curve.
        let strands = max(1, style.strands)
        let amplitude = strands > 1 ? style.wireWidth * 0.9 : 0
        let normals = local.indices.map { geo.normal(at: $0) }
        var strandLayers: [(CAShapeLayer, CAShapeLayer)] = []
        for k in 0..<strands {
            let path = Self.strand(k, of: strands, points: local, normals: normals, lengths: geo.lengths,
                                   amplitude: amplitude, pitch: style.twistPitch) { _ in 0 }
            let dark = stroke(path, color: ink, width: style.wireWidth, cap: .round)
            let shine = stroke(path, color: NSColor(white: 1, alpha: 0.14).cgColor,
                               width: max(0.3, style.wireWidth * 0.3))
            fixed.addSublayer(dark)
            fixed.addSublayer(shine)
            strandLayers.append((dark, shine))
        }
        var wireBulbs: [(holders: [CALayer], rest: CGPoint, along: CGFloat)] = []

        // The bulbs, each hanging on its lead from a point on the wire,
        // in a holder that can swing about that point.
        let dark = CALayer()
        dark.frame = root.bounds
        let indices = geo.bulbIndices(spacing: g.spacing)
        let positions = indices.map { local[$0] }
        for (i, p) in positions.enumerated() {
            let off = holder(bulbs.off, rect: bulbs.rect, wire: p, lead: style.lead,
                             leadWidth: max(0.6, style.wireWidth * 0.6), ink: ink)
            dark.addSublayer(off)
            var lit: CALayer?
            if !g.bulbsOff.contains(i) && g.mode != .off {
                let l = holder(bulbs.on, rect: bulbs.rect, wire: p, lead: style.lead, leadWidth: nil, ink: ink)
                l.opacity = Float(g.brightness)
                light.addSublayer(l)
                lit = l
            }
            swings.append(BulbSwing(center: CGPoint(x: p.x, y: p.y - style.lightDrop), off: off, lit: lit))
            wireBulbs.append(([off] + (lit.map { [$0] } ?? []), off.position, geo.lengths[indices[i]]))
        }
        wire = Wire(points: local, normals: normals, lengths: geo.lengths, amplitude: amplitude,
                    pitch: style.twistPitch, strands: strandLayers, fixed: fixed, bulbs: wireBulbs)
        dark.shouldRasterize = true
        dark.rasterizationScale = scale
        groups.append(dark)
        groups.append(light)
        // The dark garland and the lit bulbs are each cached as one bitmap.
        // The light then moves as a whole: one animation per garland, not
        // one per bulb. Blinking fades the lit bitmap in and out; the wave
        // slides a soft striped mask across it.
        fixed.shouldRasterize = true
        fixed.rasterizationScale = scale
        light.shouldRasterize = true
        light.rasterizationScale = scale
        switch g.mode {
        case .on, .off:
            break
        case .blink:
            light.add(blink(g, now: now), forKey: "light")
        case .wave:
            // The mask moves every frame, so it sits on a plain layer around
            // the cached one; on the cached layer itself it would force the
            // bitmap to be redrawn each frame.
            if let mask = waveMask(g, bulbs: positions, in: light.bounds, now: now) {
                let masked = CALayer()
                masked.frame = root.bounds
                masked.addSublayer(light)
                masked.mask = mask
                container.addSublayer(fixed)
                container.addSublayer(dark)
                container.addSublayer(masked)
                return container
            }
        }
        container.addSublayer(fixed)
        container.addSublayer(dark)
        container.addSublayer(light)
        return container
    }

    /// A bulb in its own small layer that turns about the point where its
    /// lead meets the wire. Cached as a bitmap, so a swing only turns it.
    private func holder(_ image: CGImage?, rect: CGRect, wire: CGPoint, lead: CGFloat,
                        leadWidth: CGFloat?, ink: CGColor) -> CALayer {
        let r = Sprite.aligned(rect, scale: scale)
        // The sprite's rect is measured from where the bulb hangs, y down;
        // the wire point is `lead` above that.
        let top = min(r.minY, -lead), bottom = r.maxY
        let w = r.width, h = bottom - top
        let wx = -r.minX, wy = bottom + lead
        let holder = CALayer()
        holder.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        holder.anchorPoint = CGPoint(x: wx / w, y: wy / h)
        holder.position = Sprite.snap(wire, scale: scale)
        if let leadWidth, lead > 0 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: wx, y: wy))
            path.addLine(to: CGPoint(x: wx, y: bottom))
            holder.addSublayer(stroke(path, color: ink, width: leadWidth))
        }
        holder.addSublayer(Sprite.layer(image, rect: rect, at: CGPoint(x: wx, y: bottom), scale: scale))
        holder.shouldRasterize = true
        holder.rasterizationScale = scale
        return holder
    }

    // MARK: A bird on the wire

    /// One strand of the wire, twisted around the curve, each point lowered
    /// by `drop` of its distance along the wire.
    private static func strand(_ k: Int, of strands: Int, points: [CGPoint], normals: [CGVector], lengths: [CGFloat],
                               amplitude: CGFloat, pitch: CGFloat, drop: (CGFloat) -> CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (i, p) in points.enumerated() {
            let n = normals[i]
            let o = amplitude * sin(2 * .pi * lengths[i] / max(pitch, 2) + CGFloat(k) * 2 * .pi / CGFloat(strands))
            let q = CGPoint(x: p.x + n.dx * o, y: p.y + n.dy * o - drop(lengths[i]))
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        return path
    }

    /// A weight on the wire at `p` (this layer's coordinates) pulls it
    /// `depth` points down there: like any taut string under a point load,
    /// it runs straight from each end to the weight, and the bulbs go down
    /// with it. A depth of zero puts it back as drawn and caches it again.
    func bend(at p: CGPoint, depth: CGFloat) {
        birdLoad = (p, depth)
        applyLoads()
    }

    /// A bird sitting on the wire, and a hand pulling it, each where it is
    /// and how far it pulls the wire down there.
    private var birdLoad: (point: CGPoint, depth: CGFloat) = (.zero, 0)
    private var handLoad: (point: CGPoint, depth: CGFloat) = (.zero, 0)
    private var bounce: Timer?

    /// The wire taken at `p` by a hand, before it is pulled. Taken again
    /// while it still bounces, it is held where it is now.
    func grab(at p: CGPoint) -> CGFloat {
        bounce?.invalidate()
        bounce = nil
        guard let wire, handLoad.depth != 0 else {
            handLoad = (p, 0)
            return 0
        }
        let now = drop(along: wire.lengths[nearest(to: p, on: wire)], wire: wire, load: handLoad)
        handLoad = (p, now)
        return now
    }

    /// The hand pulls the wire `depth` points down where it took it.
    func pull(depth: CGFloat) {
        bounce?.invalidate()
        bounce = nil
        handLoad.depth = depth
        applyLoads()
    }

    /// Let go, the wire springs back past its rest and bounces up and down
    /// a few times, and the bulbs on it swing as it shakes them. Driven
    /// frame by frame only while it bounces.
    func release() {
        let from = handLoad.depth
        guard abs(from) > 0.5, let wire else {
            pull(depth: 0)
            return
        }
        let start = CACurrentMediaTime()
        let frequency = 2.1, decay = 2.4
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CACurrentMediaTime() - start
                let envelope = Double(from) * exp(-decay * t)
                if abs(envelope) < 0.3 {
                    self.bounce?.invalidate()
                    self.bounce = nil
                    self.handLoad.depth = 0
                } else {
                    self.handLoad.depth = CGFloat(envelope * cos(2 * .pi * frequency * t))
                }
                self.applyLoads()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        bounce = timer
        // The jerk sets the bulbs swinging on their leads, the ones near
        // the hand most, each a moment after the one before.
        guard root.superlayer?.speed != 0, let total = wire.lengths.last, total > 0 else { return }
        let at = wire.lengths[nearest(to: handLoad.point, on: wire)]
        let now = CACurrentMediaTime()
        var until: CFTimeInterval = 0
        for (i, s) in swings.enumerated() where i < wire.bulbs.count {
            let along = wire.bulbs[i].along
            let near = Double(along < at ? along / max(at, 1) : (total - along) / max(total - at, 1))
            let kick = min(2.4, abs(Double(from)) * 0.07) * (0.3 + 0.7 * near) * .random(in: 0.6...1.2)
            let dir: Double = Bool.random() ? 1 : -1
            let curve = Self.pendulum(angle: s.angle, velocity: s.velocity + dir * kick)
            until = max(until, swing(i, curve, at: now, delay: Double(abs(along - at)) / 1800))
        }
        if until > 0 { unflatten(until: until) }
    }

    private func nearest(to p: CGPoint, on wire: Wire) -> Int {
        var nearest = 0, best = CGFloat.greatestFiniteMagnitude
        for (i, q) in wire.points.enumerated() {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < best { best = d; nearest = i }
        }
        return nearest
    }

    /// How far a load pulls the wire down `s` along it.
    private func drop(along s: CGFloat, wire: Wire, load: (point: CGPoint, depth: CGFloat)) -> CGFloat {
        guard abs(load.depth) > 0.05, let total = wire.lengths.last, total > 0 else { return 0 }
        let at = min(max(wire.lengths[nearest(to: load.point, on: wire)], 1), total - 1)
        return load.depth * (s < at ? s / at : (total - s) / (total - at))
    }

    private func applyLoads() {
        guard var wire, let total = wire.lengths.last, total > 0 else { return }
        let bent = abs(birdLoad.depth) > 0.05 || abs(handLoad.depth) > 0.05
        guard bent || wire.bent else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let w = wire, bird = birdLoad, hand = handLoad
        // Where each load sits along the wire, found once for every point.
        let birdAt = abs(bird.depth) > 0.05 ? min(max(w.lengths[nearest(to: bird.point, on: w)], 1), total - 1) : nil
        let handAt = abs(hand.depth) > 0.05 ? min(max(w.lengths[nearest(to: hand.point, on: w)], 1), total - 1) : nil
        func part(_ s: CGFloat, _ at: CGFloat?, _ depth: CGFloat) -> CGFloat {
            guard let at else { return 0 }
            return depth * (s < at ? s / at : (total - s) / (total - at))
        }
        let drop: (CGFloat) -> CGFloat = { s in part(s, birdAt, bird.depth) + part(s, handAt, hand.depth) }
        let strands = wire.strands.count
        for (k, layers) in wire.strands.enumerated() {
            let path = Self.strand(k, of: strands, points: wire.points, normals: wire.normals, lengths: wire.lengths,
                                   amplitude: wire.amplitude, pitch: wire.pitch, drop: drop)
            layers.0.path = path
            layers.1.path = path
        }
        for (i, bulb) in wire.bulbs.enumerated() {
            let q = CGPoint(x: bulb.rest.x, y: bulb.rest.y - drop(bulb.along))
            for h in bulb.holders { h.position = bent ? q : bulb.rest }
            fish[i]?.position = bent ? q : bulb.rest
        }
        // While it moves the wire is drawn as it is; still, it is cached.
        wire.fixed.shouldRasterize = !bent
        wire.bent = bent
        self.wire = wire
        if bent { unflatten(until: CACurrentMediaTime() + 0.2) }
    }

    // MARK: Fish

    /// How long a fish is for these bulbs.
    private var fishLength: CGFloat { max(14, style.bulbSize * 4.2) }

    /// Hangs fish on bulbs `wanted` and takes them off the others, at once
    /// (after a rebuild) or, `animated`, the new ones dropping into place.
    func setFish(_ wanted: Set<Int>, animated: Bool) {
        guard let wire else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (i, layer) in fish where !wanted.contains(i) {
            layer.removeFromSuperlayer()
            fish[i] = nil
            showBulb(i, true)
        }
        let picture = FishSprite.picture(length: fishLength, scale: scale)
        let ink = NSColor(white: 0.045, alpha: 1).cgColor
        for i in wanted where fish[i] == nil && i < wire.bulbs.count && i < swings.count {
            let h = holder(picture.image, rect: picture.rect, wire: wire.bulbs[i].holders.first?.position ?? wire.bulbs[i].rest,
                           lead: style.lead, leadWidth: max(0.6, style.wireWidth * 0.6), ink: ink)
            fishLayer.addSublayer(h)
            fish[i] = h
            swings[i].fish = h
            showBulb(i, false)
            if animated {
                // Drops in on its lead with a little bounce.
                let drop = CAKeyframeAnimation(keyPath: "transform.scale")
                drop.values = [0.2, 1.12, 0.96, 1]
                drop.keyTimes = [0, 0.5, 0.78, 1]
                drop.duration = 0.45
                h.add(drop, forKey: "appear")
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.2
                h.add(fade, forKey: "fade")
                touch(bulb: i)
            }
        }
        unflatten(until: CACurrentMediaTime() + 0.5)
    }

    /// Where each fish hangs now, by bulb: the middle of its body, in this
    /// layer's coordinates.
    func fishPoints() -> [Int: CGPoint] {
        fish.mapValues { CGPoint(x: $0.position.x, y: $0.position.y - style.lead - fishLength * 0.6) }
    }

    /// A gull snatches the fish on bulb `i`: it jerks up and is gone, the
    /// lead swings, and a moment later the bulb lights up there again.
    func snatchFish(_ i: Int) {
        guard let layer = fish[i] else { return }
        fish[i] = nil
        if i < swings.count { swings[i].fish = nil }
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let up = CABasicAnimation(keyPath: "position.y")
        up.byValue = fishLength * 0.8
        let gone = CABasicAnimation(keyPath: "opacity")
        gone.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [up, gone]
        group.duration = 0.12
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "snatch")
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.fish[i] == nil, i < self.swings.count else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.showBulb(i, true)
            for l in [self.swings[i].off, self.swings[i].lit].compactMap({ $0 }) {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [0.1, 1.15, 0.97, 1]
                pop.keyTimes = [0, 0.55, 0.8, 1]
                pop.duration = 0.4
                l.add(pop, forKey: "pop")
            }
            CATransaction.commit()
            self.touch(bulb: i)
            self.unflatten(until: CACurrentMediaTime() + 0.6)
        }
        unflatten(until: CACurrentMediaTime() + 1.5)
    }

    private func showBulb(_ i: Int, _ shown: Bool) {
        guard i < swings.count else { return }
        swings[i].off.isHidden = !shown
        swings[i].lit?.isHidden = !shown
    }

    // MARK: Air from the pointer

    /// One bulb's swing, kept so a new push continues from where it is.
    private struct BulbSwing {
        let center: CGPoint
        let off: CALayer
        let lit: CALayer?
        var fish: CALayer?
        var curve: [Double] = []
        var start: CFTimeInterval = 0
        var pushed: CFTimeInterval = 0
        /// The swing is a smooth curve: 15 points a second, eased between
        /// by Core Animation, look the same as 30 and cost half.
        static let step = 1.0 / 15
        /// New pushes at most 15 times a second: the push builds up over
        /// time anyway, and a fifteenth of a second is too short to see.
        static let pushEvery = 1.0 / 15

        var angle: Double {
            guard !curve.isEmpty else { return 0 }
            let t = (CACurrentMediaTime() - start) / Self.step
            if t <= 0 { return curve[0] }
            if t >= Double(curve.count - 1) { return 0 }
            let i = Int(t), f = t - Double(i)
            return curve[i] + (curve[i + 1] - curve[i]) * f
        }

        /// How fast it is swinging now, in radians a second.
        var velocity: Double {
            guard curve.count > 1 else { return 0 }
            let t = (CACurrentMediaTime() - start) / Self.step
            if t <= 0 || t >= Double(curve.count - 1) { return 0 }
            let i = Int(t)
            return (curve[i + 1] - curve[i]) / Self.step
        }
    }

    /// A hand passing by the bulbs: each one within reach is pushed the way
    /// the air moves, more the closer and the faster, the push reaching
    /// farther bulbs a moment later, and swings on its lead like a small
    /// pendulum until it hangs still. Worked out once per push and played
    /// by Core Animation; while bulbs swing they are separate layers, and
    /// a few seconds after the last one stops they are flattened again.
    func feelAir(at p: CGPoint, velocity v: CGVector) {
        guard !swings.isEmpty, root.superlayer?.speed != 0 else { return }
        let speed = hypot(v.dx, v.dy)
        guard speed > 30 else { return }
        let now = CACurrentMediaTime()
        var until: CFTimeInterval = 0
        for (i, s) in swings.enumerated() {
            let d = hypot(p.x - s.center.x, p.y - s.center.y)
            guard d < reach, now - s.pushed >= BulbSwing.pushEvery else { continue }
            let near = pow(1 - d / reach, 1.4)
            // Air pushes like drag: with the square of the hand's speed,
            // for as long as it blows on the bulb. A slow hand barely stirs
            // it; a quick sweep sets it going.
            let strength = min(7, pow(Double(speed) / 580, 2)) * Double(near)
            let blowing = min(0.1, now - s.pushed)
            // It gives the bulb speed, not a new angle: air moving right
            // pushes its bottom right, which with the pivot above is a
            // counter-clockwise turn, positive. Pushes in time with the
            // swing add up, as on a swing.
            let kick = Double(v.dx / max(speed, 1)) * 14 * strength * blowing
            guard abs(kick) > 0.05 else { continue }
            let curve = Self.pendulum(angle: s.angle, velocity: s.velocity + kick)
            until = max(until, swing(i, curve, at: now, delay: Double(d) / 2200))
        }
        if until > 0 { unflatten(until: until) }
    }

    /// Plays `curve` on bulb `i`, starting `delay` after `now`, and returns
    /// when it ends.
    private func swing(_ i: Int, _ curve: [Double], at now: CFTimeInterval, delay: Double) -> CFTimeInterval {
        let s = swings[i]
        swings[i].curve = curve
        swings[i].start = now + delay
        swings[i].pushed = now
        let a = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        a.values = curve
        a.calculationMode = .cubic
        a.duration = BulbSwing.step * Double(curve.count - 1)
        a.beginTime = now + delay
        // Keep the current lean until the air arrives.
        a.fillMode = .backwards
        if #available(macOS 12.0, *) {
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        }
        s.off.add(a, forKey: "swing")
        s.lit?.add(a, forKey: "swing")
        s.fish?.add(a, forKey: "swing")
        return now + delay + a.duration
    }

    /// The pointer resting on bulb `i`: it starts to sway a little by
    /// itself and keeps swaying gently for as long as the pointer is there,
    /// each touch in time with the swing, like a hand on a swing.
    func touch(bulb i: Int) {
        guard i < swings.count, root.superlayer?.speed != 0 else { return }
        let s = swings[i]
        let a = s.angle, w = s.velocity
        // How far it swings now, from where it is and how fast it goes.
        let reach = (a * a + w * w / 22).squareRoot()
        let now = CACurrentMediaTime()
        guard reach < 0.1, now - s.pushed > 0.28 else { return }
        let dir: Double = abs(w) > 0.05 ? (w > 0 ? 1 : -1) : (Bool.random() ? 1 : -1)
        unflatten(until: swing(i, Self.pendulum(angle: a, velocity: w + dir * 0.28), at: now, delay: 0))
    }

    /// A small pendulum set going from `angle` at `velocity`: it carries
    /// on by its own inertia, about 1.3 seconds to and fro, dying
    /// away slowly. Worked out once, in small steps, until it is still.
    /// The swing never goes past about 45 degrees.
    private static func pendulum(angle a0: Double, velocity w0: Double) -> [Double] {
        let k = 22.0, c = 0.8, limit = 0.8
        let step = BulbSwing.step, sub = 8, dt = step / Double(sub)
        var a = a0, w = w0
        var curve = [a]
        for _ in 0..<Int(8 / step) {
            for _ in 0..<sub {
                w += (-k * a - c * w) * dt
                a += w * dt
                // Past the limit it is held back softly, like a lead pulled taut.
                if abs(a) > limit { a = limit * (a > 0 ? 1 : -1); w *= -0.3 }
            }
            curve.append(a)
            if abs(a) < 0.004 && abs(w) < 0.03 { break }
        }
        curve.append(0)
        return curve
    }

    /// Lets the bulbs move on their own until `until`, then caches them
    /// as bitmaps again.
    private func unflatten(until: CFTimeInterval) {
        for g in groups where g.shouldRasterize { g.shouldRasterize = false }
        flattenTimer?.invalidate()
        // A second of slack, so quick repeated pushes do not flatten and
        // unflatten the bitmaps over and over.
        let timer = Timer(timeInterval: max(0.1, until - CACurrentMediaTime() + 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flattenTimer = nil
                for g in self.groups { g.shouldRasterize = true }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flattenTimer = timer
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

    /// All bulbs going out and lighting up again together.
    private func blink(_ g: Garland, now: CFTimeInterval) -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = GarlandLight.blinkValues
        a.keyTimes = GarlandLight.blinkTimes.map { NSNumber(value: $0) }
        a.duration = GarlandLight.blinkPeriod / g.speed
        a.repeatCount = .infinity
        a.beginTime = now
        a.isRemovedOnCompletion = false
        a.calm()
        return a
    }

    /// The running wave as one mask: soft bright stripes, one wavelength
    /// apart, sliding along the garland by one wavelength per cycle. The
    /// wavelength is where bulb i lags its neighbour by `waveLag`, so it
    /// matches the per-bulb wave it replaces.
    private func waveMask(_ g: Garland, bulbs: [CGPoint], in bounds: CGRect, now: CFTimeInterval) -> CALayer? {
        guard bulbs.count > 1, let first = bulbs.first, let last = bulbs.last else { return nil }
        let rightward = last.x >= first.x
        let perBulb = max(4, abs(last.x - first.x) / CGFloat(bulbs.count - 1))
        let lambda = perBulb * 2 * .pi / CGFloat(GarlandLight.waveLag)
        let periods = Int((bounds.width / lambda).rounded(.up)) + 2
        let perPeriod = 16
        let n = periods * perPeriod
        let mask = CAGradientLayer()
        mask.frame = CGRect(x: bounds.minX - lambda, y: bounds.minY, width: lambda * CGFloat(periods), height: bounds.height)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = (0...n).map { j in
            let phase = 2 * Double.pi * Double(j) / Double(perPeriod) * (rightward ? -1 : 1)
            return NSColor(white: 0, alpha: GarlandLight.wave(phase: phase)).cgColor
        }
        let a = CABasicAnimation(keyPath: "position.x")
        a.byValue = rightward ? lambda : -lambda
        a.duration = 2 * .pi / (GarlandLight.waveRate * g.speed)
        a.repeatCount = .infinity
        a.beginTime = now
        a.isRemovedOnCompletion = false
        a.calm()
        mask.add(a, forKey: "wave")
        return mask
    }
}
