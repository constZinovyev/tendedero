import Foundation
import Testing
@testable import NotesCore

@Suite struct MarkdownTests {
    @Test func titlesSkipMarkup() {
        #expect(Markdown.title(of: "\n\n## План на день\nтекст") == "План на день")
        #expect(Markdown.title(of: "- [x] **Позвонить** маме") == "Позвонить маме")
        #expect(Markdown.title(of: "![](../attachments/a.png)\nСкриншот ошибки") == "Скриншот ошибки")
        #expect(Markdown.title(of: "Смотри [статью](https://example.com)") == "Смотри статью")
        #expect(Markdown.title(of: "   ") == "")
    }

    @Test func tasksToggleOnlyOnTheirMark() {
        let text = "Утро\n- [ ] зарядка\n  * [x] кофе\n"
        let ns = text as NSString
        let first = ns.range(of: "[ ]").location
        #expect(Markdown.taskMark(in: ns, at: first + 1)?.done == false)
        #expect(Markdown.taskMark(in: ns, at: ns.range(of: "зарядка").location + 2) == nil)
        #expect(Markdown.taskMark(in: ns, at: ns.range(of: "[x]").location)?.done == true)
        #expect(Markdown.togglingTask(in: text, at: first) == "Утро\n- [x] зарядка\n  * [x] кофе\n")
        #expect(Markdown.togglingTask(in: text, at: ns.range(of: "кофе").location) == "Утро\n- [ ] зарядка\n  * [ ] кофе\n")
        #expect(Markdown.togglingTask(in: text, at: 1) == nil)
    }

    @Test func findsImagesAndLinks() {
        let text = "![экран](../attachments/ab.png \"заголовок\") и [сайт](https://a.b/c) ![](x.jpg)"
        #expect(Markdown.images(in: text).map(\.path) == ["../attachments/ab.png", "x.jpg"])
        #expect(Markdown.images(in: text).first?.alt == "экран")
        #expect(Markdown.links(in: text).map(\.url) == ["https://a.b/c"])
        #expect(Markdown.linkMarkdown(title: "a [b]", url: "u") == "[a (b)](u)")
    }
}
