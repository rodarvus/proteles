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

    // MARK: - Real-format tag handling (from a live capture)

    @Test("makeArticle drops {helpbody}/{/helpbody} marker lines")
    func dropsBodyMarkers() {
        let body = [
            line("{helpkeywords}Help Keywords : CONSIDER."),
            line("{helpbody}"),
            line("Syntax: consider <monster>"),
            line("{/helpbody}")
        ]
        let article = HelpParser.makeArticle(from: body, isSearch: false)
        #expect(!article.lines.contains { $0.text.contains("{helpbody}") })
        #expect(!article.lines.contains { $0.text.contains("{/helpbody}") })
        #expect(article.lines.contains { $0.text == "Syntax: consider <monster>" })
    }

    @Test("The {helpkeywords} inline prefix is stripped from the keyword line")
    func stripsKeywordsTag() {
        let body = [line("{helpkeywords}Help Keywords : CONSIDER.")]
        let article = HelpParser.makeArticle(from: body, isSearch: false)
        #expect(article.lines.first?.text == "Help Keywords : CONSIDER.")
        #expect(!(article.lines.first?.text.contains("{helpkeywords}") ?? true))
    }

    @Test("Each help keyword becomes a help <keyword> link")
    func linkifiesKeywords() {
        let result = HelpParser.linkifyHelpKeywords(line("Help Keywords : Maxstats Maxtrains."))
        let links = result.runs.compactMap(\.link?.action)
        #expect(links.contains(.sendCommand("help Maxstats")))
        #expect(links.contains(.sendCommand("help Maxtrains")))
        // The "Help Keywords" label itself is never linked.
        #expect(!links.contains(.sendCommand("help Help")))
    }

    @Test("Quoted inline help references become clickable commands")
    func inlineQuotedHelpReferences() {
        let text = #"The exprate wish ('help wish') and "help combat empathy" use this toggle."#
        let result = HelpParser.linkifyInlineHelpReferences(line(text))
        let links = result.runs.compactMap(\.link?.action)

        #expect(links.contains(.sendCommand("help wish")))
        #expect(links.contains(.sendCommand("help combat empathy")))
        #expect(result.runs.first {
            $0.link?.action == .sendCommand("help wish")
        }?.utf16Range == utf16Range(of: "help wish", in: text))
    }

    @Test("Inline help references are case-insensitive but require quotes")
    func inlineHelpRequiresQuotes() {
        let text = #"See 'Help power up', "not a help link", and help unquoted."#
        let result = HelpParser.linkifyInlineHelpReferences(line(text))
        let links = result.runs.compactMap(\.link?.action)

        #expect(links == [.sendCommand("Help power up")])
    }

    @Test("makeArticle applies inline help links in body text")
    func articleAssemblyLinkifiesInlineHelp() {
        let body = [
            line("You lose experience by death (see 'help death').")
        ]
        let article = HelpParser.makeArticle(from: body, isSearch: false)
        let links = article.lines.flatMap { $0.runs.compactMap(\.link?.action) }

        #expect(links.contains(.sendCommand("help death")))
    }

    @Test("Title is derived from the help keyword(s) when present")
    func titleFromKeywords() {
        let body = [
            line("----------------------------------------"),
            line("{helpkeywords}Help Keywords : CONSIDER."),
            line("Help Category : Information."),
            line("{helpbody}"),
            line("body"),
            line("{/helpbody}")
        ]
        let article = HelpParser.makeArticle(from: body, isSearch: false)
        #expect(article.title == "CONSIDER")
    }
}
