import AppKit
import ImageIO
import NotesCore
import UniformTypeIdentifiers

extension NSAttributedString.Key {
    /// The Markdown an attachment character stands for, like `![](../attachments/ab.png)`.
    static let markdownSource = NSAttributedString.Key("TendederoMarkdownSource")
}

/// An editor whose text is Markdown, styled as you type: headings, tasks
/// that tick with a click, links, and pictures shown inline. A picture is a
/// single character carrying its Markdown, so it is deleted, cut and pasted
/// as one piece, and the page saves back to plain Markdown.
///
/// Only the lines an edit touches are restyled, and pictures are decoded at
/// the size they are shown, so big screenshots cost little memory.
final class MarkdownTextView: NSTextView, NSTextStorageDelegate {
    var notebook: Notebook!
    var section = ""
    var onChange: ((String) -> Void)?
    private var loading = false

    var bodySize: CGFloat = 15
    /// Font families for the text and the headings; the system font when nil.
    var bodyFamily: String?
    var headingFamily: String?
    var ink = NSColor.labelColor
    /// The colour of the task boxes.
    var accent = NSColor.controlAccentColor

    func bodyFont(_ size: CGFloat) -> NSFont {
        bodyFamily.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    }

    func headingFont(_ size: CGFloat) -> NSFont {
        headingFamily.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: .bold)
    }
    static let headingSizes: [CGFloat] = [26, 21, 18, 16, 15, 15]

    var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        return [.font: bodyFont(bodySize), .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    func configure() {
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        textContainerInset = NSSize(width: 28, height: 24)
        typingAttributes = baseAttributes
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textStorage?.delegate = self
    }

    // MARK: Markdown in and out

    func load(_ markdown: String) {
        loading = true
        defer { loading = false }
        let text = NSMutableAttributedString(string: markdown, attributes: baseAttributes)
        let ns = markdown as NSString
        for match in Markdown.image.matches(in: markdown, range: NSRange(location: 0, length: ns.length)).reversed() {
            text.replaceCharacters(in: match.range, with: picture(source: ns.substring(with: match.range), path: ns.substring(with: match.range(at: 2))))
        }
        textStorage?.setAttributedString(text)
        undoManager?.removeAllActions()
        setSelectedRange(NSRange(location: text.length, length: 0))
    }

    var markdown: String {
        guard let storage = textStorage else { return "" }
        let ns = storage.string as NSString
        var out = ""
        storage.enumerateAttribute(.markdownSource, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            let piece = ns.substring(with: range)
            if let source = value as? String {
                for character in piece { out += character == "\u{FFFC}" ? source : String(character) }
            } else {
                out += piece.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }

    override func didChangeText() {
        super.didChangeText()
        typingAttributes = baseAttributes
        if !loading { onChange?(markdown) }
    }

    // MARK: Styling

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        restyle(textStorage, in: editedRange)
    }

    /// Restyles the lines around `range`. Runs while the storage processes an
    /// edit, so it only changes attributes.
    private func restyle(_ storage: NSTextStorage, in range: NSRange) {
        let string = storage.string
        let ns = string as NSString
        let lines = ns.paragraphRange(for: range)
        guard lines.length > 0 else { return }
        storage.addAttributes(baseAttributes, range: lines)
        for key in [NSAttributedString.Key.link, .strikethroughStyle, .backgroundColor] { storage.removeAttribute(key, range: lines) }
        // Typed text can inherit a picture's attributes; only pictures keep them.
        storage.enumerateAttribute(.markdownSource, in: lines) { value, run, _ in
            guard value != nil else { return }
            for i in run.location..<NSMaxRange(run) where ns.character(at: i) != 0xFFFC {
                storage.removeAttribute(.markdownSource, range: NSRange(location: i, length: 1))
                storage.removeAttribute(.attachment, range: NSRange(location: i, length: 1))
            }
        }

        let dim = NSColor.tertiaryLabelColor
        let each = { (re: NSRegularExpression, body: (NSTextCheckingResult) -> Void) in
            re.enumerateMatches(in: string, range: lines) { match, _, _ in if let match { body(match) } }
        }
        each(Markdown.heading) { m in
            let level = m.range(at: 1).length
            storage.addAttribute(.font, value: headingFont(Self.headingSizes[level - 1] * bodySize / 15), range: m.range)
            storage.addAttribute(.foregroundColor, value: dim, range: m.range(at: 1))
        }
        each(Markdown.bullet) { m in storage.addAttribute(.foregroundColor, value: dim, range: m.range) }
        each(Markdown.quote) { m in storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range) }
        each(Markdown.task) { m in
            let marker = NSRange(location: m.range(at: 1).upperBound, length: m.range.upperBound - m.range(at: 1).upperBound)
            storage.addAttributes([.foregroundColor: accent, .cursor: NSCursor.pointingHand,
                                   .font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .medium)], range: marker)
            if ns.substring(with: m.range(at: 2)) != " " {
                let line = ns.lineRange(for: m.range)
                let rest = NSRange(location: m.range.upperBound, length: line.upperBound - m.range.upperBound)
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: rest)
            }
        }
        each(Markdown.bold) { m in
            storage.applyFontTraits(.boldFontMask, range: m.range)
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: m.range.upperBound - 2, length: 2))
        }
        each(Markdown.italic) { m in storage.applyFontTraits(.italicFontMask, range: m.range) }
        each(Markdown.code) { m in
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular),
                                   .backgroundColor: NSColor.quaternaryLabelColor], range: m.range)
        }
        var linked: [NSRange] = []
        each(Markdown.link) { m in
            linked.append(m.range)
            storage.addAttributes([.foregroundColor: dim, .font: bodyFont(bodySize - 3)], range: m.range)
            storage.addAttribute(.font, value: bodyFont(bodySize), range: m.range(at: 1))
            if let url = notebook?.resolve(ns.substring(with: m.range(at: 2)), inSection: section) {
                storage.addAttribute(.link, value: url, range: m.range(at: 1))
            }
        }
        Self.urlDetector.enumerateMatches(in: string, range: lines) { m, _, _ in
            guard let m, let url = m.url, !linked.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) else { return }
            storage.addAttribute(.link, value: url, range: m.range)
        }
    }

    private static let urlDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: Pictures

    /// Pictures are decoded once at this width and only scaled down to fit.
    private static let pictureLimit: CGFloat = 640

    private var pictureWidth: CGFloat {
        let width = (textContainer?.size.width ?? 0) - 2 * (textContainer?.lineFragmentPadding ?? 0)
        return width > 40 && width < 10_000 ? min(width, Self.pictureLimit) : Self.pictureLimit
    }

    private func fitted(_ size: CGSize) -> CGRect {
        let scale = min(1, pictureWidth / max(size.width, 1))
        return CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    private var fittedWidth: CGFloat = 0

    /// Keeps pictures as wide as the column at most, as the window resizes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard abs(pictureWidth - fittedWidth) >= 1, let storage = textStorage, let layout = layoutManager else { return }
        fittedWidth = pictureWidth
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
            let bounds = fitted(image.size)
            guard bounds != attachment.bounds else { return }
            attachment.bounds = bounds
            layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    /// The picture as one character, or the Markdown as text when the file
    /// is not in the notebook (a web picture, a missing file).
    private func picture(source: String, path: String) -> NSAttributedString {
        guard let url = notebook?.resolve(path, inSection: section), url.isFileURL,
              let image = Thumbnails.image(at: url, maxWidth: Self.pictureLimit) else {
            return NSAttributedString(string: source, attributes: baseAttributes)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = fitted(image.size)
        let text = NSMutableAttributedString(attachment: attachment)
        let whole = NSRange(location: 0, length: text.length)
        text.addAttributes(baseAttributes, range: whole)
        text.addAttribute(.markdownSource, value: source, range: whole)
        return text
    }

    /// Inserts Markdown pieces each on a line of its own.
    private func insertBlocks(_ pieces: [String]) {
        guard !pieces.isEmpty else { return }
        let out = NSMutableAttributedString()
        let location = selectedRange().location
        if location > 0, (string as NSString).character(at: location - 1) != 10 {
            out.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        for piece in pieces {
            let ns = piece as NSString
            if let m = Markdown.image.firstMatch(in: piece, range: NSRange(location: 0, length: ns.length)), m.range.length == ns.length {
                out.append(picture(source: piece, path: ns.substring(with: m.range(at: 2))))
            } else {
                out.append(NSAttributedString(string: piece, attributes: baseAttributes))
            }
            out.append(NSAttributedString(string: "\n", attributes: baseAttributes))
        }
        insertText(out, replacementRange: selectedRange())
    }

    private func markdown(forFile url: URL) -> String? {
        let type = UTType(filenameExtension: url.pathExtension)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // Big files would bloat the repository; they get a link to where they are.
        guard size <= 25_000_000, let data = try? Data(contentsOf: url),
              let link = try? notebook.importAttachment(data, fileExtension: url.pathExtension) else {
            return Markdown.linkMarkdown(title: url.lastPathComponent, url: url.absoluteString)
        }
        if type?.conforms(to: .image) == true { return Markdown.imageMarkdown(path: link) }
        return Markdown.linkMarkdown(title: url.lastPathComponent, url: link)
    }

    // MARK: Paste and drop

    private static let accepted: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .string, .URL]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { Self.accepted }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.accepted }

    override func preferredPasteboardType(from available: [NSPasteboard.PasteboardType], restrictedToTypesFrom allowed: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
        // Text copied from a rich app often comes with a picture of itself.
        let richText = available.contains(.rtf) || available.contains(.html)
        let order: [NSPasteboard.PasteboardType] = richText ? [.fileURL, .string, .png, .tiff, .URL] : [.fileURL, .png, .tiff, .string, .URL]
        return order.first { available.contains($0) && (allowed?.contains($0) ?? true) }
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .fileURL:
            let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            insertBlocks(urls.compactMap(markdown(forFile:)))
            return true
        case .png, .tiff:
            guard let data = pboard.data(forType: type) else { return false }
            guard let png = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]),
                  let link = try? notebook.importAttachment(png, fileExtension: "png") else { return false }
            insertBlocks([Markdown.imageMarkdown(path: link)])
            return true
        case .string, .URL:
            guard let text = pboard.string(forType: .string) ?? pboard.string(forType: .URL) else { return false }
            insertText(text, replacementRange: selectedRange())
            return true
        default:
            return super.readSelection(from: pboard, type: type)
        }
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        if let index = characterIndex(atViewPoint: convert(event.locationInWindow, from: nil)), let storage = textStorage {
            if let mark = Markdown.taskMark(in: storage.string as NSString, at: index) {
                let tick = mark.done ? " " : "x"
                if shouldChangeText(in: mark.range, replacementString: tick) {
                    storage.replaceCharacters(in: mark.range, with: tick)
                    didChangeText()
                }
                return
            }
            if event.clickCount == 2, let source = storage.attribute(.markdownSource, at: index, effectiveRange: nil) as? String,
               let path = Markdown.images(in: source).first?.path, let url = notebook.resolve(path, inSection: section) {
                NSWorkspace.shared.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The character drawn under a point, or nil between lines and past their ends.
    private func characterIndex(atViewPoint point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: p, in: container)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(p) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }
}

/// Pictures decoded at the size they are shown, kept while memory allows.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL, maxWidth: CGFloat, maxHeight: CGFloat = 420) -> NSImage? {
        let key = "\(url.path)|\(Int(maxWidth))" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat, pixelWidth > 0, pixelHeight > 0 else { return nil }
        // Retina screenshots say 144 dpi: their size in points is half their pixels.
        let dpi = properties[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        var size = CGSize(width: pixelWidth * 72 / dpi, height: pixelHeight * 72 / dpi)
        let fit = min(1, maxWidth / size.width, maxHeight / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * scale,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: size)
        cache.setObject(image, forKey: key)
        return image
    }
}
