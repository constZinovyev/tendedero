import AppKit
import CoreImage
import QuartzCore

/// Pictures drawn once and then only moved, faded or swayed by Core Animation.
/// The decorations hang on the desktop all day, so everything that does not
/// change is flattened into images up front: compositing an image costs the
/// GPU almost nothing, while gradients, masks and blurs redrawn every frame
/// would keep the WindowServer busy.
enum Sprite {
    /// Draws into a bitmap of `rect` (in points), with y growing downward
    /// like the design pages' canvas, so their drawing code ports directly.
    static func draw(_ rect: CGRect, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        let rect = aligned(rect, scale: scale)
        let w = max(1, Int((rect.width * scale).rounded()))
        let h = max(1, Int((rect.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        body(ctx)
        return ctx.makeImage()
    }

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// A soft-edged copy of an image. Done once, when the sprite is made.
    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard radius > 0.1 else { return image }
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        return ci.createCGImage(output, from: input.extent)
    }

    /// One image drawn over another, both of the same size.
    static func stack(_ images: [CGImage?], size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for image in images.compactMap({ $0 }) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return ctx.makeImage()
    }

    /// A layer showing `image`, placed so that the sprite's local point
    /// (0, 0) lands on `anchor` (AppKit coordinates). `rect` is the rect the
    /// sprite was drawn for, in its local y-down coordinates.
    static func layer(_ image: CGImage?, rect: CGRect, at anchor: CGPoint, scale: CGFloat) -> CALayer {
        let rect = aligned(rect, scale: scale)
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = scale
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        // The local origin, measured in the layer's own y-up unit space.
        layer.anchorPoint = CGPoint(x: -rect.minX / rect.width, y: rect.maxY / rect.height)
        layer.position = snap(anchor, scale: scale)
        return layer
    }

    /// A sprite's rect grown out to whole device pixels. The bitmap and the
    /// layer showing it then match pixel for pixel: a layer a fraction of a
    /// pixel off in size or place would be resampled, and every sprite would
    /// look slightly soft.
    static func aligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = (rect.minX * scale).rounded(.down) / scale, minY = (rect.minY * scale).rounded(.down) / scale
        let maxX = (rect.maxX * scale).rounded(.up) / scale, maxY = (rect.maxY * scale).rounded(.up) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A point on the device pixel grid.
    static func snap(_ p: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: (p.x * scale).rounded() / scale, y: (p.y * scale).rounded() / scale)
    }

    // MARK: Drawing helpers, in the canvas' terms

    static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    }

    /// Fills the current clip with a radial gradient, like canvas'
    /// createRadialGradient with both circles at one centre.
    static func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ stops: [(CGFloat, CGColor)]) {
        ctx.drawRadialGradient(gradient(stops), startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius, options: [])
    }

    static func radial(_ ctx: CGContext, from c0: CGPoint, r0: CGFloat, to c1: CGPoint, r1: CGFloat, _ stops: [(CGFloat, CGColor)]) {
        ctx.drawRadialGradient(gradient(stops), startCenter: c0, startRadius: r0,
                               endCenter: c1, endRadius: r1, options: [.drawsAfterEndLocation])
    }

    static func linear(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, _ stops: [(CGFloat, CGColor)]) {
        ctx.drawLinearGradient(gradient(stops), start: a, end: b,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Runs `body` clipped to `path`.
    static func clipped(_ ctx: CGContext, _ path: CGPath, _ body: () -> Void) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        body()
        ctx.restoreGState()
    }

    static func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, width: CGFloat, cap: CGLineCap = .round) {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, rotation: CGFloat = 0) -> CGPath {
        var t = CGAffineTransform(translationX: cx, y: cy).rotated(by: rotation)
        return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: &t)
    }

    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: min(max(a, 0), 1))
    }
}

/// Animations on the decorations run at a calm rate. Flicker and a slow
/// wave read just as well at 24–30 frames a second, and the display does
/// not have to recomposite the desktop at 120.
extension CAAnimation {
    func calm() {
        if #available(macOS 12.0, *) {
            preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
        }
    }
}
