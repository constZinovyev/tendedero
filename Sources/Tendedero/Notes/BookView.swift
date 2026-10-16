import AppKit
import Combine
import NotesCore

/// Where everything sits in the open book, y up, in the book panel.
enum BookGeometry {
    static let page = CGSize(width: 300, height: 400)
    static let border: CGFloat = 8
    static let side: CGFloat = 28
    static let bottom: CGFloat = 34
    static let top: CGFloat = 40
    /// How far the stickers reach past the pages.
    static let tabReach: CGFloat = 64

    static var base: CGRect {
        CGRect(x: side, y: bottom, width: page.width * 2 + border * 2, height: page.height + border * 2)
    }
    static var left: CGRect { CGRect(x: side + border, y: bottom + border, width: page.width, height: page.height) }
    static var right: CGRect { CGRect(x: side + border + page.width, y: bottom + border, width: page.width, height: page.height) }
    static var spineX: CGFloat { right.minX }
    /// The front cover as it lies closed over the right page.
    static var cover: CGRect {
        CGRect(x: spineX, y: bottom, width: page.width + border, height: page.height + border * 2)
    }
    static var size: CGSize { CGSize(width: base.maxX + tabReach + side, height: base.maxY + top) }
}

/// The open notebook: a spread of two pages on a linen cover, stickers on
/// the right for the sections. The left page lists the section's pages,
/// the right one is the page itself, written in Markdown.
///
/// Opening, closing and turning pages are drawn by Core Animation over the
/// real pages, from pictures of them; between those moments nothing redraws.
@MainActor
final class BookView: NSView {
    let store: NotesStore
    var onClose: (() -> Void)?

    private let base = CoverBase()
    private let tabs = TabsView()
    private let leftPage = PaperView(spineOnLeft: false)
    private let rightPage = PaperView(spineOnLeft: true)
    private let index = NSTextView()
    private let editor: MarkdownTextView
    private let editorScroll = NSScrollView()
    private let dateLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let overlay = StageView()
    private var stage: CALayer { overlay.stage }

    private var loaded = ""
    private(set) var animating = false
    private var observers = Set<AnyCancellable>()

    init(store: NotesStore) {
        self.store = store
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        editor = MarkdownTextView(frame: .zero, textContainer: container)
        super.init(frame: CGRect(origin: .zero, size: BookGeometry.size))
        wantsLayer = true
        build()
        store.$pages.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshIndex() } }.store(in: &observers)
        store.$editorRevision.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.reload(force: true) } }.store(in: &observers)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func build() {
        base.frame = BookGeometry.base
        addSubview(base)

        tabs.frame = CGRect(x: BookGeometry.right.maxX - 14, y: BookGeometry.right.minY,
                            width: BookGeometry.tabReach + 14, height: BookGeometry.page.height)
        tabs.onSelect = { [weak self] i in self?.selectSection(at: i) }
        addSubview(tabs)

        leftPage.frame = BookGeometry.left
        rightPage.frame = BookGeometry.right
        addSubview(leftPage)
        addSubview(rightPage)

        index.frame = leftPage.bounds.insetBy(dx: 26, dy: 26)
        // A fixed frame: grown to fit, it would keep its bottom and the
        // list would sink to the foot of the page.
        index.isVerticallyResizable = false
        index.isEditable = false
        index.isSelectable = true
        index.drawsBackground = false
        index.textContainerInset = .zero
        index.delegate = self
        index.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        leftPage.addSubview(index)

        let size = BookGeometry.page
        dateLabel.frame = CGRect(x: 24, y: size.height - 30, width: size.width - 48, height: 16)
        dateLabel.alignment = .right
        dateLabel.font = NSFont(name: NotebookLook.body, size: 11)
        dateLabel.textColor = NotebookLook.pencil
        rightPage.addSubview(dateLabel)

        editorScroll.frame = CGRect(x: 22, y: 40, width: size.width - 40, height: size.height - 76)
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.bodySize = 14
        editor.bodyFamily = NotebookLook.body
        editor.headingFamily = NotebookLook.hand
        editor.ink = NotebookLook.ink
        editor.accent = NSColor(red: 0.33, green: 0.42, blue: 0.33, alpha: 1)
        editor.configure()
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 2, height: 2)
        editor.insertionPointColor = NotebookLook.ink
        editorScroll.documentView = editor
        editor.frame = NSRect(origin: .zero, size: editorScroll.contentSize)
        rightPage.addSubview(editorScroll)

        for (button, title, action) in [(previous, "‹", #selector(previousPage)), (next, "›", #selector(nextPage))] {
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont(name: NotebookLook.hand, size: 26) ?? .systemFont(ofSize: 22),
                .foregroundColor: NotebookLook.pencil])
            button.target = self
            button.action = action
            rightPage.addSubview(button)
        }
        previous.frame = CGRect(x: size.width / 2 - 64, y: 8, width: 30, height: 28)
        next.frame = CGRect(x: size.width / 2 + 34, y: 8, width: 30, height: 28)
        pageLabel.frame = CGRect(x: size.width / 2 - 34, y: 14, width: 68, height: 16)
        pageLabel.alignment = .center
        pageLabel.font = NSFont(name: NotebookLook.body, size: 11)
        pageLabel.textColor = NotebookLook.pencil
        rightPage.addSubview(pageLabel)

        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        overlay.place(spine: CGPoint(x: BookGeometry.spineX, y: BookGeometry.base.midY))
    }

    // MARK: Content

    private var section: NotebookSection? { store.sections.first { $0.folder == store.selectedSection } }

    /// Fills both pages from the store; a section with no pages gets one.
    func reload(force: Bool = false) {
        if store.selectedSection == nil { store.selectedSection = store.sections.first?.folder }
        if store.selectedPage == nil, store.selectedSection != nil { store.newPage() }
        refreshIndex()
        tabs.set(store.sections.map { ($0.title, NotebookLook.nsColor($0.color)) },
                 selected: store.sections.firstIndex { $0.folder == store.selectedSection })
        guard let page = store.selectedPage else { return }
        let key = "\(page.id)#\(store.editorRevision)"
        if force || key != loaded {
            loaded = key
            editor.notebook = store.notebook
            editor.section = page.section
            editor.load(page.text)
        }
        let id = page.id
        editor.onChange = { [weak self] text in self?.store.editorChanged(text, page: id) }
        if let created = page.created {
            dateLabel.stringValue = Self.dateFormat.string(from: created)
        }
        let pages = store.pages
        let n = (pages.firstIndex { $0.id == page.id } ?? 0) + 1
        pageLabel.stringValue = "\(n) / \(pages.count)"
        previous.isEnabled = n > 1
    }

    private func refreshIndex() {
        guard let section else { return }
        let ink = NotebookLook.ink, pencil = NotebookLook.pencil
        let text = NSMutableAttributedString()
        let title = NSFont(name: NotebookLook.hand, size: 30) ?? .boldSystemFont(ofSize: 26)
        text.append(NSAttributedString(string: section.title + "\n", attributes: [
            .font: title, .foregroundColor: ink,
            .underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NotebookLook.nsColor(section.color)]))
        let small = NSFont(name: NotebookLook.body, size: 11) ?? .systemFont(ofSize: 11)
        text.append(NSAttributedString(string: Self.todayFormat.string(from: Date()) + "\n\n",
                                       attributes: [.font: small, .foregroundColor: pencil]))
        let row = NSMutableParagraphStyle()
        row.paragraphSpacing = 7
        row.tabStops = [NSTextTab(textAlignment: .left, location: BookGeometry.page.width - 100)]
        row.lineBreakMode = .byTruncatingTail
        for page in store.pages.reversed() {
            let selected = page.id == store.selectedPageID
            let name = page.title.isEmpty ? "без названия" : page.title
            let font = NSFont(name: selected ? "AvenirNext-DemiBold" : NotebookLook.body, size: 13) ?? .systemFont(ofSize: 13)
            let line = NSMutableAttributedString(string: (selected ? "▸ " : "· ") + Self.clip(name, 24), attributes: [
                .font: font, .foregroundColor: page.title.isEmpty ? pencil : ink, .paragraphStyle: row,
                .link: URL(string: "notes://page/\(page.id)")!])
            if let created = page.created {
                line.append(NSAttributedString(string: "\t" + Self.shortFormat.string(from: created), attributes: [
                    .font: small, .foregroundColor: pencil, .paragraphStyle: row]))
            }
            line.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: row]))
            text.append(line)
        }
        text.append(NSAttributedString(string: "\n+ новая страница", attributes: [
            .font: NSFont(name: NotebookLook.hand, size: 16) ?? small, .foregroundColor: pencil,
            .link: URL(string: "notes://new")!]))
        index.textStorage?.setAttributedString(text)
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count > n ? s.prefix(n - 1) + "…" : s }

    private static let dateFormat = format("d MMMM, HH:mm")
    private static let todayFormat = format("EEEE, d MMMM")
    private static let shortFormat = format("d MMM")

    private static func format(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    func focusEditor() {
        window?.makeFirstResponder(editor)
    }

    // MARK: Moving around

    /// Where a page is, for telling which way to turn: by sticker, then by page.
    private func place(section folder: String?, page id: String?) -> (Int, Int) {
        let s = store.sections.firstIndex { $0.folder == folder } ?? 0
        let p = folder.map { store.notebook.pages(in: $0).firstIndex { $0.id == id } ?? 0 } ?? 0
        return (s, p)
    }

    /// Leaves the current page, dropping it if nothing was written on it.
    private func leavePage() {
        store.saveNow()
        if let page = store.selectedPage, page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.deletePage(page.id)
        }
    }

    private func go(_ change: () -> Void) {
        guard !animating else { return }
        let before = place(section: store.selectedSection, page: store.selectedPageID)
        turn(change: {
            change()
            reload()
        }, forward: { [weak self] in
            guard let self else { return true }
            let after = self.place(section: self.store.selectedSection, page: self.store.selectedPageID)
            return after >= before
        })
    }

    func selectSection(at i: Int) {
        guard store.sections.indices.contains(i), store.sections[i].folder != store.selectedSection else { return }
        go {
            leavePage()
            store.selectedSection = store.sections[i].folder
        }
    }

    private func selectPage(_ id: String) {
        guard id != store.selectedPageID else { return }
        go {
            leavePage()
            store.selectedPageID = id
        }
    }

    private func newPage() {
        go {
            leavePage()
            store.newPage()
        }
    }

    @objc private func previousPage() {
        let pages = store.pages
        guard let i = pages.firstIndex(where: { $0.id == store.selectedPageID }), i > 0 else { return }
        selectPage(pages[i - 1].id)
    }

    /// Past the last page comes a blank one.
    @objc private func nextPage() {
        let pages = store.pages
        guard let i = pages.firstIndex(where: { $0.id == store.selectedPageID }) else { return }
        if i + 1 < pages.count {
            selectPage(pages[i + 1].id)
        } else if !(pages[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            newPage()
        }
    }

    // MARK: Animations

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func snapshot(_ view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// The inside of the front cover with the left page on it, as it shows
    /// while the cover turns.
    private func insideCover() -> CGImage? {
        let size = BookGeometry.cover.size
        let s = scale
        guard let left = snapshot(leftPage),
              let ctx = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.setFillColor(NotebookLook.insideCover.cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        ctx.draw(left, in: CGRect(x: BookGeometry.border, y: BookGeometry.border, width: BookGeometry.page.width, height: BookGeometry.page.height))
        return ctx.makeImage()
    }

    private lazy var coverFront: CGImage? = NotebookLook.coverImage(size: BookGeometry.cover.size, scale: scale)

    private func setPages(visible: Bool, left: Bool = true) {
        for view in [base, rightPage, tabs] as [NSView] { view.alphaValue = visible ? 1 : 0 }
        leftPage.alphaValue = visible && left ? 1 : 0
    }

    /// The transform that shows the cover, turning about its spine, over `rect`.
    private func coverTransform(to rect: CGRect) -> CATransform3D {
        let c = BookGeometry.cover
        let s = rect.width / c.width
        var t = CATransform3DMakeTranslation(rect.minX - c.minX, rect.midY - c.midY, 0)
        t = CATransform3DRotate(t, -3 * .pi / 180, 0, 0, 1)
        t = CATransform3DScale(t, s, rect.height / c.height * 1, 1)
        return t
    }

    /// Takes the cover from `start` (where the notebook hangs, in this view's
    /// coordinates) to the middle of the panel, then opens it.
    func open(from start: CGRect, done: @escaping () -> Void) {
        animating = true
        reload()
        setPages(visible: false)
        let card = Leaf(front: coverFront, back: insideCover(), frame: BookGeometry.cover, hinge: 0, in: overlay)
        card.layer.transform = coverTransform(to: start)
        stage.addSublayer(card.layer)

        let fly = CABasicAnimation(keyPath: "transform")
        fly.fromValue = NSValue(caTransform3D: card.layer.transform)
        fly.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        fly.duration = 0.42
        fly.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
        card.layer.transform = CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            Rustle.play()
            card.turn(to: -.pi, duration: 0.8) {
                self.leftPage.alphaValue = 1
                card.layer.removeFromSuperlayer()
                self.animating = false
                self.focusEditor()
                done()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                self.tabs.animator().alphaValue = 1
            }
        }
        card.layer.add(fly, forKey: "fly")
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.base.animator().alphaValue = 1
            self.rightPage.animator().alphaValue = 1
        }
    }

    /// Closes the cover and takes the notebook back to `end` on the line.
    func close(to end: CGRect, done: @escaping () -> Void) {
        guard !animating else { return }
        animating = true
        leavePageIfBlank()
        store.saveNow()
        let card = Leaf(front: coverFront, back: insideCover(), frame: BookGeometry.cover, hinge: 0, in: overlay)
        card.layer.setValue(-CGFloat.pi, forKeyPath: "transform.rotation.y")
        card.shade(turned: true)
        stage.addSublayer(card.layer)
        leftPage.alphaValue = 0
        Rustle.play()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            self.tabs.animator().alphaValue = 0
        }
        card.turn(from: -.pi, to: 0, duration: 0.7) { [weak self] in
            guard let self else { return }
            self.setPages(visible: false)
            let target = self.coverTransform(to: end)
            let fly = CABasicAnimation(keyPath: "transform")
            fly.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
            fly.toValue = NSValue(caTransform3D: target)
            fly.duration = 0.36
            fly.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.8, 0.4)
            card.layer.transform = target
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                card.layer.removeFromSuperlayer()
                self.animating = false
                done()
            }
            card.layer.add(fly, forKey: "fly")
            CATransaction.commit()
        }
    }

    private func leavePageIfBlank() {
        if let page = store.selectedPage, store.pages.count > 1,
           page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.deletePage(page.id)
            reload()
        }
    }

    /// Turns a leaf: forward over to the left, or back over to the right.
    /// Pictures of the old pages cover the real ones until the leaf lands.
    private func turn(change: () -> Void, forward: () -> Bool) {
        animating = true
        let oldLeft = snapshot(leftPage), oldRight = snapshot(rightPage)
        change()
        let isForward = forward()
        let newLeft = snapshot(leftPage), newRight = snapshot(rightPage)

        let under = CALayer()
        under.contents = isForward ? oldLeft : oldRight
        under.frame = overlay.toStage(isForward ? BookGeometry.left : BookGeometry.right)
        stage.addSublayer(under)
        let leaf = isForward
            ? Leaf(front: oldRight, back: newLeft, frame: BookGeometry.right, hinge: 0, in: overlay)
            : Leaf(front: oldLeft, back: newRight, frame: BookGeometry.left, hinge: 1, in: overlay)
        stage.addSublayer(leaf.layer)
        Rustle.play(soft: true)
        leaf.turn(to: isForward ? -.pi : .pi, duration: 0.6) { [weak self] in
            under.removeFromSuperlayer()
            leaf.layer.removeFromSuperlayer()
            self?.animating = false
            self?.focusEditor()
        }
    }
}

extension BookView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard textView === index, let url = link as? URL, url.scheme == "notes" else { return false }
        if url.host == "new" {
            newPage()
        } else if url.host == "page" {
            selectPage(url.lastPathComponent)
        }
        return true
    }
}

/// A leaf in Core Animation: a picture on each side, turning about one edge.
/// It darkens a little as it turns away from the light.
@MainActor
final class Leaf {
    let layer = CATransformLayer()
    private let frontShade = CALayer()
    private let backShade = CALayer()

    init(front: CGImage?, back: CGImage?, frame: CGRect, hinge: CGFloat, in overlay: StageView) {
        let f = overlay.toStage(frame)
        layer.bounds = CGRect(origin: .zero, size: f.size)
        layer.anchorPoint = CGPoint(x: hinge, y: 0.5)
        layer.position = CGPoint(x: f.minX + hinge * f.width, y: f.midY)
        for (side, image, shade, flipped) in [(CALayer(), front, frontShade, false), (CALayer(), back, backShade, true)] {
            side.frame = layer.bounds
            side.contents = image
            side.contentsGravity = .resize
            side.isDoubleSided = false
            side.cornerRadius = 3
            side.masksToBounds = true
            if flipped { side.transform = CATransform3DMakeRotation(.pi, 0, 1, 0) }
            shade.frame = side.bounds
            shade.backgroundColor = NSColor.black.cgColor
            shade.opacity = flipped ? 0.3 : 0
            side.addSublayer(shade)
            layer.addSublayer(side)
        }
    }

    func shade(turned: Bool) {
        frontShade.opacity = turned ? 0.3 : 0
        backShade.opacity = turned ? 0 : 0.3
    }

    func turn(from start: CGFloat = 0, to angle: CGFloat, duration: CFTimeInterval, done: @escaping () -> Void) {
        let timing = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.25, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let spin = CABasicAnimation(keyPath: "transform.rotation.y")
        spin.fromValue = start
        spin.toValue = angle
        spin.duration = duration
        spin.timingFunction = timing
        layer.setValue(angle, forKeyPath: "transform.rotation.y")
        layer.add(spin, forKey: "turn")
        let turned = angle != 0
        for (shade, to) in [(frontShade, turned ? Float(0.3) : 0), (backShade, turned ? 0 : Float(0.3))] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = shade.opacity
            fade.toValue = to
            fade.duration = duration
            fade.timingFunction = timing
            shade.opacity = to
            shade.add(fade, forKey: "shade")
        }
        CATransaction.commit()
    }
}

/// A layer-hosting view over the book where the moving leaves are drawn,
/// in perspective from the spine. It never takes a click.
final class StageView: NSView {
    let stage = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(stage)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Centres the perspective on the spine.
    func place(spine: CGPoint) {
        let reach: CGFloat = 1600
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.frame = CGRect(x: spine.x - reach, y: spine.y - reach, width: reach * 2, height: reach * 2)
        var p = CATransform3DIdentity
        p.m34 = -1 / 1500
        stage.sublayerTransform = p
        CATransaction.commit()
    }

    func toStage(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -stage.frame.minX, dy: -stage.frame.minY) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The cover under the pages, with the edges of the leaves showing below.
final class CoverBase: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -8)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NotebookLook.insideCover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        // The stack of leaves, a few hairlines under each page.
        let b = BookGeometry.border
        for i in 1...3 {
            NSColor(white: 0.96 - CGFloat(i) * 0.03, alpha: 1).setFill()
            let y = b - CGFloat(i) * 1.6
            NSRect(x: b + 2, y: y, width: bounds.width - 2 * b - 4, height: 1.2).fill()
        }
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSRect(x: bounds.midX - 0.5, y: b - 4, width: 1, height: bounds.height - 2 * b + 8).fill()
    }
}

/// A page of dotted paper, a little darker towards the spine.
final class PaperView: NSView {
    let spineOnLeft: Bool

    init(spineOnLeft: Bool) {
        self.spineOnLeft = spineOnLeft
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NotebookLook.paper.setFill()
        bounds.fill()
        NotebookLook.dots.setFill()
        let step: CGFloat = 18
        var y = bounds.height - 22
        while y > 14 {
            var x: CGFloat = 18
            while x < bounds.width - 12 {
                NSBezierPath(ovalIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)).fill()
                x += step
            }
            y -= step
        }
        let shade = NSGradient(starting: NSColor.black.withAlphaComponent(0.14), ending: NSColor.black.withAlphaComponent(0))
        let width: CGFloat = 30
        let rect = spineOnLeft ? NSRect(x: 0, y: 0, width: width, height: bounds.height)
                               : NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        shade?.draw(in: rect, angle: spineOnLeft ? 0 : 180)
    }
}

/// The stickers along the right edge, one per section. The open one stands
/// out a little further.
final class TabsView: NSView {
    var onSelect: ((Int) -> Void)?
    private var tabs: [(String, NSColor)] = []
    private var selected: Int?

    func set(_ tabs: [(String, NSColor)], selected: Int?) {
        self.tabs = tabs
        self.selected = selected
        needsDisplay = true
    }

    private func rect(at i: Int) -> NSRect {
        let h: CGFloat = 34, gap: CGFloat = 8
        let y = bounds.height - 24 - CGFloat(i + 1) * h - CGFloat(i) * gap
        let reach = i == selected ? bounds.width : bounds.width - 8
        return NSRect(x: 0, y: y, width: reach, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont(name: "AvenirNext-DemiBold", size: 10) ?? .boldSystemFont(ofSize: 10)
        for (i, tab) in tabs.enumerated() {
            let r = rect(at: i)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            tab.1.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            let ink = tab.1.blended(withFraction: 0.72, of: .black) ?? .black
            let text = NSAttributedString(string: tab.0, attributes: [.font: font, .foregroundColor: ink])
            let size = text.size()
            // The first 14 points are under the page.
            let room = NSRect(x: 20, y: r.midY - size.height / 2, width: r.width - 26, height: size.height)
            text.draw(with: room, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = tabs.indices.first(where: { rect(at: $0).contains(p) }) { onSelect?(i) }
    }

    override func resetCursorRects() {
        for i in tabs.indices { addCursorRect(rect(at: i), cursor: .pointingHand) }
    }
}
