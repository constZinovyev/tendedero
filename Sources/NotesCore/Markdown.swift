import Foundation

/// The bits of Markdown the notebook understands. Patterns work line by
/// line, so an editor can restyle only the lines that changed.
public enum Markdown {
    public static let heading = pattern("^(#{1,6})[ \\t]+.*$")
    /// `- [ ]` or `- [x]` at the start of a line; group 2 is the mark.
    public static let task = pattern("^([ \\t]*)[-*+] \\[([ xX])\\](?=[ \\t]|$)")
    public static let bullet = pattern("^[ \\t]*(?:[-*+]|\\d+[.)])(?=[ \\t])")
    public static let quote = pattern("^>[ \\t]?.*$")
    /// `![alt](path)`; group 1 is alt, group 2 the path.
    public static let image = pattern("!\\[([^\\]\\n]*)\\]\\(([^)\\s]+)(?:[ \\t]+\"[^\"\\n]*\")?\\)")
    /// `[title](url)`; group 1 is the title, group 2 the url.
    public static let link = pattern("(?<!!)\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)")
    public static let bold = pattern("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    public static let italic = pattern("(?<![*\\w])\\*(?=[^\\s*])([^*\\n]+?)(?<=[^\\s*])\\*(?![*\\w])")
    public static let code = pattern("`[^`\\n]+`")

    private static let linePrefix = pattern("^[ \\t]*(?:#{1,6}[ \\t]+|[-*+][ \\t]+(?:\\[[ xX]\\][ \\t]*)?|\\d+[.)][ \\t]+|>[ \\t]?)")

    /// The page's name: its first line with words in it, without Markdown.
    public static func title(of text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            var s = String(line)
            s = replace(linePrefix, in: s, with: "")
            s = replace(image, in: s, with: "")
            s = replace(link, in: s, with: "$1")
            s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            s = s.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { return String(s.prefix(80)) }
        }
        return ""
    }

    /// The mark of the task whose `- [ ]` holds `location`, if one does.
    public static func taskMark(in text: NSString, at location: Int) -> (range: NSRange, done: Bool)? {
        guard location >= 0, location <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: min(location, max(text.length - 1, 0)), length: 0))
        guard let match = task.firstMatch(in: text as String, range: line) else { return nil }
        let marker = NSRange(location: match.range(at: 1).upperBound, length: match.range.upperBound - match.range(at: 1).upperBound)
        guard NSLocationInRange(location, marker) else { return nil }
        let mark = match.range(at: 2)
        return (mark, text.substring(with: mark) != " ")
    }

    /// The text with the task on the line holding `location` ticked or unticked.
    public static func togglingTask(in text: String, at location: Int) -> String? {
        let ns = text as NSString
        let line = ns.lineRange(for: NSRange(location: min(location, max(ns.length - 1, 0)), length: 0))
        guard let match = task.firstMatch(in: text, range: line) else { return nil }
        let mark = match.range(at: 2)
        return ns.replacingCharacters(in: mark, with: ns.substring(with: mark) == " " ? "x" : " ")
    }

    public static func images(in text: String) -> [(alt: String, path: String)] {
        let ns = text as NSString
        return image.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    public static func links(in text: String) -> [(title: String, url: String)] {
        let ns = text as NSString
        return link.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    public static func imageMarkdown(path: String, alt: String = "") -> String { "![\(alt)](\(path))" }

    public static func linkMarkdown(title: String, url: String) -> String {
        let clean = title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(clean)](\(url))"
    }

    private static func pattern(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
