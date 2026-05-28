import Foundation
@testable import MudCore
import Testing

@Suite("Session logging — formatter + logger")
struct SessionLoggingTests {
    private func line(_ text: String, _ runs: [StyledRun] = []) -> Line {
        Line(id: LineID(0), text: text, runs: runs)
    }

    // MARK: - Formatter

    @Test("Text format is the line's plain text")
    func textFormat() {
        #expect(SessionLogFormatter.text(line("You are carrying: a sword")) == "You are carrying: a sword")
    }

    @Test("HTML escapes markup and wraps coloured runs in a span")
    func htmlFormat() {
        let red = StyleAttributes(foreground: .named(.red))
        let text = "a <fire> sword"
        let len = (text as NSString).length
        let html = SessionLogFormatter.htmlLine(
            line(text, [StyledRun(utf16Range: 0..<len, style: red)]),
            palette: .xtermDefault
        )
        #expect(html.contains("&lt;fire&gt;")) // escaped
        #expect(html.contains("<span style=\"color:#")) // coloured span
    }

    @Test("A plain line produces no spans")
    func htmlPlain() {
        let html = SessionLogFormatter.htmlLine(line("just words"), palette: .xtermDefault)
        #expect(html == "just words")
    }

    // MARK: - Logger

    @Test("Text logger writes each appended line to the file")
    func textLogger() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let logger = try #require(SessionLogger(url: url, format: .text))
        await logger.append(line("first line"))
        await logger.append(line("second line"))
        await logger.close()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "first line\nsecond line\n")
    }

    @Test("HTML logger writes a header, span lines, and a footer")
    func htmlLogger() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: url) }
        let logger = try #require(SessionLogger(url: url, format: .html))
        await logger.append(line("hello"))
        await logger.close()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("<!DOCTYPE html>"))
        #expect(contents.contains("hello"))
        #expect(contents.contains("</pre></body></html>"))
    }

    @Test("Appends after close are ignored")
    func appendAfterClose() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let logger = try #require(SessionLogger(url: url, format: .text))
        await logger.append(line("kept"))
        await logger.close()
        await logger.append(line("dropped"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == "kept\n")
    }
}
