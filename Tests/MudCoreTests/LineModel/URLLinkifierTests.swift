import Foundation
@testable import MudCore
import Testing

@Suite("URLLinkifier — mark URLs as hyperlinks")
struct URLLinkifierTests {
    private func line(_ text: String, _ runs: [StyledRun] = []) -> Line {
        Line(id: LineID(0), text: text, runs: runs)
    }

    private func utf16Range(of needle: String, in text: String) -> Range<Int> {
        let ns = text as NSString
        let range = ns.range(of: needle)
        return range.lowerBound..<range.upperBound
    }

    @Test("A line with no URL is returned unchanged")
    func noURL() {
        let plain = line("just some words here")
        #expect(URLLinkifier.linkify(plain) == plain)
    }

    @Test("A URL substring becomes an .openURL link over its exact range")
    func detectsURL() {
        let text = "see http://example.com/path now"
        let result = URLLinkifier.linkify(line(text))
        let linked = result.runs.first { $0.link != nil }
        #expect(linked?.utf16Range == utf16Range(of: "http://example.com/path", in: text))
        #expect(linked?.link?.action == .openURL("http://example.com/path"))
        #expect(result.text == text) // text is never altered
    }

    @Test("A URL inside a coloured run keeps the run's colour")
    func preservesStyle() {
        let red = StyleAttributes(foreground: .named(.red))
        let text = "go https://aardwolf.com"
        let len = (text as NSString).length
        let result = URLLinkifier.linkify(line(text, [StyledRun(utf16Range: 0..<len, style: red)]))
        let linked = result.runs.first { $0.link != nil }
        #expect(linked?.style.foreground == .named(.red))
        #expect(linked?.link?.action == .openURL("https://aardwolf.com"))
    }

    @Test("mailto links are detected too")
    func mailto() {
        let result = URLLinkifier.linkify(line("mail me at mailto:a@b.com please"))
        #expect(result.runs.contains { $0.link?.action == .openURL("mailto:a@b.com") })
    }

    @Test("Aardwolf say echo URLs inside quotes are detected")
    func quotedSayEcho() {
        let text = "You say 'http://www.google.com/'"
        let result = URLLinkifier.linkify(line(text))
        let linked = result.runs.first { $0.link != nil }

        #expect(linked?.utf16Range == utf16Range(of: "http://www.google.com/", in: text))
        #expect(linked?.link?.action == .openURL("http://www.google.com/"))
    }

    @Test("A URL followed by prose stops at the first space")
    func URLFollowedByProse() {
        let text = "Zargulis answers 'https://www.aardwolf.com/wiki/index.php/Main/MudMessages "
            + "has a lot of mud messages'"
        let result = URLLinkifier.linkify(line(text))
        let linked = result.runs.first { $0.link != nil }

        #expect(linked?.utf16Range == utf16Range(
            of: "https://www.aardwolf.com/wiki/index.php/Main/MudMessages",
            in: text
        ))
        #expect(linked?.link?.action == .openURL(
            "https://www.aardwolf.com/wiki/index.php/Main/MudMessages"
        ))
    }
}
