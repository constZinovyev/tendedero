import SwiftUI

/// The look of the notebook, shared by the one hanging on the line and the
/// open book.
enum NotebookLook {
    static let linen = Color(red: 0.79, green: 0.81, blue: 0.77)
    static let linenDark = Color(red: 0.62, green: 0.65, blue: 0.60)
    static let band = Color(red: 0.30, green: 0.33, blue: 0.28)
    static let insideCover = NSColor(red: 0.70, green: 0.73, blue: 0.68, alpha: 1)
    static let paper = NSColor(red: 1.0, green: 0.992, blue: 0.972, alpha: 1)
    static let dots = NSColor(red: 0.80, green: 0.77, blue: 0.70, alpha: 1)
    static let ink = NSColor(red: 0.17, green: 0.17, blue: 0.22, alpha: 1)
    static let pencil = NSColor(red: 0.47, green: 0.46, blue: 0.43, alpha: 1)
    /// Handwriting for titles; the body stays an easy read.
    static let hand = "Bradley Hand"
    static let body = "Avenir Next"

    /// The closed notebook's size on the line, without its stickers.
    static let hangingSize = CGSize(width: 92, height: 124)
    static let tabReach: CGFloat = 7

    static func color(_ hex: String) -> Color {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func nsColor(_ hex: String) -> NSColor {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        return NSColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// The cover as a picture, for the open book's animations.
    @MainActor
    static func coverImage(size: CGSize, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: NotebookCover().frame(width: size.width, height: size.height))
        renderer.scale = scale
        return renderer.cgImage
    }
}

/// A linen cover with an elastic band and a paper label. It scales with
/// the size it is given.
struct NotebookCover: View {
    var title = "заметки"

    var body: some View {
        GeometryReader { g in
            let k = g.size.width / NotebookLook.hangingSize.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2 * k, style: .continuous)
                    .fill(NotebookLook.linenDark)
                RoundedRectangle(cornerRadius: 5 * k, style: .continuous)
                    .fill(NotebookLook.linen)
                    .overlay(LinenWeave(step: 2.2 * k).clipShape(RoundedRectangle(cornerRadius: 5 * k, style: .continuous)))
                    .padding(.leading, 4 * k)
                // The spine, a little darker where the cover bends.
                Rectangle()
                    .fill(LinearGradient(colors: [NotebookLook.linenDark, NotebookLook.linen.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 12 * k)
                    .padding(.leading, 4 * k)
                // The paper label.
                Text(title)
                    .font(.custom(NotebookLook.hand, size: 13 * k))
                    .foregroundStyle(NotebookLook.band)
                    .padding(.horizontal, 7 * k)
                    .padding(.vertical, 3 * k)
                    .background(RoundedRectangle(cornerRadius: 2 * k).fill(Color(nsColor: NotebookLook.paper)))
                    .overlay(RoundedRectangle(cornerRadius: 2 * k).stroke(NotebookLook.band.opacity(0.25), lineWidth: 0.6 * k))
                    .rotationEffect(.degrees(-2))
                    .offset(x: 18 * k, y: 30 * k)
                // The elastic band.
                Rectangle()
                    .fill(NotebookLook.band)
                    .frame(width: 4.5 * k, height: g.size.height)
                    .offset(x: g.size.width - 15 * k)
                    .shadow(color: .black.opacity(0.25), radius: 0.8 * k, x: 0.8 * k)
            }
        }
    }
}

/// The weave of the cloth: faint threads both ways, drawn once.
private struct LinenWeave: View {
    let step: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var light = Path(), dark = Path()
            var y: CGFloat = 0, n = 0
            while y < size.height {
                let r = CGRect(x: 0, y: y, width: size.width, height: 0.5)
                if n % 3 == 0 { dark.addRect(r) } else { light.addRect(r) }
                y += step; n += 1
            }
            var x: CGFloat = 0; n = 0
            while x < size.width {
                let r = CGRect(x: x, y: 0, width: 0.5, height: size.height)
                if n % 4 == 1 { dark.addRect(r) } else { light.addRect(r) }
                x += step; n += 1
            }
            ctx.fill(light, with: .color(.white.opacity(0.16)))
            ctx.fill(dark, with: .color(.black.opacity(0.06)))
        }
        .allowsHitTesting(false)
    }
}

/// The closed notebook on its clothespin. A click opens it; dragging slides
/// it along the rope like a photo; pulled down hard, it comes off the pin
/// and can be put anywhere. The breeze sways it.
struct NotebookOnLine: View {
    @ObservedObject var line: Line
    let width: CGFloat

    @State private var swing: Double = 0
    @State private var dragStart: Double?
    @State private var hovering = false
    /// How far it is stretched down off the pin, before it comes away.
    @State private var pull: CGFloat = 0
    static let tearDistance: CGFloat = 70

    private var size: CGSize { NotebookLook.hangingSize }

    var body: some View {
        let x = CGFloat(line.notebookPosition) * width
        let ropeY = Layout.ropeY(x: x, width: width)
        let height = size.height + 26 - 12
        VStack(spacing: -12) {
            Clothespin().zIndex(1)
            ZStack(alignment: .topLeading) {
                // Stickers peek out on the right, under the cover.
                VStack(spacing: 4) {
                    ForEach(Array(line.notebookTabs.enumerated()), id: \.offset) { _, hex in
                        RoundedRectangle(cornerRadius: 2).fill(NotebookLook.color(hex))
                            .frame(width: 14, height: 15)
                    }
                }
                .offset(x: size.width - 14 + NotebookLook.tabReach, y: 18)
                NotebookCover()
                    .frame(width: size.width, height: size.height)
                    .shadow(color: .black.opacity(hovering ? 0.30 : 0.22), radius: hovering ? 9 : 6, y: hovering ? 6 : 4)
            }
            .frame(width: size.width + NotebookLook.tabReach, height: size.height, alignment: .topLeading)
            .scaleEffect(hovering && !line.notebookOpen ? 1.03 : 1, anchor: .top)
            .offset(y: pull)
            .opacity(line.notebookOpen || line.notebookTearing ? 0 : 1)
            .background(GeometryReader { g in
                Color.clear.preference(key: NotebookRectKey.self, value: g.frame(in: .global))
            })
        }
        .rotationEffect(.degrees(-3 + swing), anchor: .top)
        .frame(width: size.width + NotebookLook.tabReach, height: height, alignment: .top)
        .position(x: x, y: ropeY - Layout.pinAbove + height / 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    if line.notebookTearing {
                        line.onNotebookFreeDrag?()
                        return
                    }
                    if dragStart == nil { dragStart = line.notebookPosition }
                    let down = max(0, drag.translation.height)
                    // The pin holds on, then lets go.
                    pull = down * 0.4
                    if down > Self.tearDistance, let start = dragStart {
                        pull = 0
                        line.moveNotebook(to: start)
                        line.notebookDragging = true
                        line.notebookTearing = true
                        line.onNotebookTearOff?()
                        return
                    }
                    guard abs(drag.translation.width) > 3 || down > 3 || line.notebookDragging, let start = dragStart else { return }
                    line.notebookDragging = true
                    let before = line.notebookPosition
                    line.moveNotebook(to: start + Double(drag.translation.width / max(width, 1)))
                    // It trails behind the pin as it slides.
                    withAnimation(.interactiveSpring) { swing = max(-12, min(12, (line.notebookPosition - before) * Double(width) * 0.9)) }
                }
                .onEnded { _ in
                    dragStart = nil
                    if line.notebookTearing {
                        line.notebookTearing = false
                        line.notebookDragging = false
                        line.onNotebookFreeDrop?()
                        return
                    }
                    if pull > 0 {
                        withAnimation(.interpolatingSpring(stiffness: 120, damping: 9)) { pull = 0 }
                    }
                    if line.notebookDragging {
                        line.notebookDragging = false
                        line.saveNotebookPosition()
                        settle(from: swing)
                    } else {
                        line.onNotebookTap?()
                    }
                }
        )
        .onPreferenceChange(NotebookRectKey.self) { rect in
            MainActor.assumeIsolated { line.notebookRect = rect }
        }
        .onChange(of: line.gust) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0...0.4)) { settle(from: .random(in: 1.2...2.6)) }
        }
        .onChange(of: line.notebookOpen) { _, open in if !open { settle(from: 5) } }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }

    /// A heavier swing than a photo's: it is a notebook, not a print.
    private func settle(from degrees: Double) {
        swing = degrees
        withAnimation(.interpolatingSpring(stiffness: 38, damping: 3.2)) { swing = 0 }
    }
}

struct NotebookRectKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
