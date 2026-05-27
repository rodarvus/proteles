import Foundation
@testable import MudCore
import Testing

@Suite("HelpParser — detect tags + linkify cross-references")
struct HelpParserTests {
    private func line(_ text: String, _ runs: [StyledRun] = []) -> Line {
        Line(id: LineID(0), text: text, runs: runs)
    }

    private func utf16Range(of needle: String, in text: String) -> Range<Int> {
        let ns = text as NSString
        let range = ns.range(of: needle)
        return range.lowerBound..<range.upperBound
    }

    // MARK: - Tag detection

    @Test("Open tags are classified search vs. plain; others are nil")
    func openTags() {
        #expect(HelpParser.openTag("{help}") == false)
        #expect(HelpParser.openTag("{helpsearch}") == true)
        #expect(HelpParser.openTag("{exits}[ Exits: north ]") == nil)
        #expect(HelpParser.openTag("Some help text") == nil)
    }

    @Test("Close tags are recognised for both block kinds")
    func closeTags() {
        #expect(HelpParser.isCloseTag("{/help}"))
        #expect(HelpParser.isCloseTag("{/helpsearch}"))
        #expect(!HelpParser.isCloseTag("{/exits}"))
        #expect(!HelpParser.isCloseTag("{help}"))
    }

    // MARK: - Related Helps linkification

    @Test("Each Related Helps topic becomes a help <topic> link over its range")
    func relatedHelpsLinks() {
        let text = "Related Helps : combat, weapons, armor"
        let result = HelpParser.linkifyRelatedHelps(line(text))
        let links = result.runs.compactMap(\.link)
        #expect(links.contains(LineLink(action: .sendCommand("help combat"), hint: "help combat")))
        #expect(links.contains(LineLink(action: .sendCommand("help weapons"), hint: "help weapons")))
        #expect(links.contains(LineLink(action: .sendCommand("help armor"), hint: "help armor")))
        // The "Related Helps" label itself is never linked.
        #expect(!links.contains { $0.action == .sendCommand("help Related") })
        #expect(result.text == text) // text is preserved
    }

    @Test("A topic link covers exactly the topic's character range")
    func linkRange() {
        let text = "Related Helps : combat"
        let result = HelpParser.linkifyRelatedHelps(line(text))
        let linked = result.runs.first { $0.link != nil }
        #expect(linked?.utf16Range == utf16Range(of: "combat", in: text))
    }

    @Test("Multi-word topics stay one link")
    func multiWordTopic() {
        let text = "Related Helps : two handed, combat"
        let result = HelpParser.linkifyRelatedHelps(line(text))
        let links = result.runs.compactMap(\.link?.action)
        #expect(links.contains(.sendCommand("help two handed")))
        #expect(links.contains(.sendCommand("help combat")))
    }

    @Test("A non-Related-Helps line is returned unchanged")
    func nonRelatedUnchanged() {
        let plain = line("This is ordinary help body text about combat.")
        #expect(HelpParser.linkifyRelatedHelps(plain) == plain)
    }

    // MARK: - Article assembly

    @Test("makeArticle derives the title from the first non-empty line + linkifies")
    func articleAssembly() {
        let body = [
            line(""),
            line("COMBAT"),
            line("Some text."),
            line("Related Helps : flee, kill")
        ]
        let article = HelpParser.makeArticle(from: body, isSearch: false)
        #expect(article.title == "COMBAT")
        #expect(!article.isSearch)
        #expect(article.lines.count == 4)
        let links = article.lines.flatMap { $0.runs.compactMap(\.link?.action) }
        #expect(links.contains(.sendCommand("help flee")))
        #expect(links.contains(.sendCommand("help kill")))
    }

    @Test("An empty search body falls back to a sensible title")
    func emptySearchTitle() {
        let article = HelpParser.makeArticle(from: [], isSearch: true)
        #expect(article.title == "Help search")
        #expect(article.isSearch)
    }
}
