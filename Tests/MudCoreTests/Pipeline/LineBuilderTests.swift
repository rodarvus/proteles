@testable import MudCore
import Testing

// MARK: - Harness

private enum LineBuilderHarness {
    static func collect(_ events: [ANSIEvent]) -> [Line] {
        var builder = LineBuilder()
        var lines: [Line] = []
        for event in events {
            builder.consume(event) { lines.append($0) }
        }
        builder.flush { lines.append($0) }
        return lines
    }
}

// MARK: - Basic

@Suite("LineBuilder — basic line assembly")
struct LineBuilderBasicTests {
    @Test("Empty input emits no lines")
    func emptyInputEmitsNoLines() {
        let lines = LineBuilderHarness.collect([])
        #expect(lines.isEmpty)
    }

    @Test("Single text + LF emits one default-styled line")
    func singleTextWithLF() {
        let lines = LineBuilderHarness.collect([
            .text("hello", .default),
            .lineFeed
        ])
        #expect(lines.count == 1)
        #expect(lines[0].text == "hello")
        #expect(lines[0].runs.isEmpty)
    }

    @Test("Multiple lines emit in order")
    func multipleLines() {
        let lines = LineBuilderHarness.collect([
            .text("first", .default),
            .lineFeed,
            .text("second", .default),
            .lineFeed
        ])
        #expect(lines.map(\.text) == ["first", "second"])
    }

    @Test("Trailing text without LF is emitted on flush")
    func trailingTextFlushed() {
        let lines = LineBuilderHarness.collect([
            .text("partial", .default)
        ])
        #expect(lines.map(\.text) == ["partial"])
    }

    @Test("Multiple text events concatenate within a line")
    func textConcatenatesWithinLine() {
        let lines = LineBuilderHarness.collect([
            .text("foo", .default),
            .text("bar", .default),
            .lineFeed
        ])
        #expect(lines.map(\.text) == ["foobar"])
    }

    @Test("Bare LF emits an empty line")
    func bareLFEmitsEmptyLine() {
        let lines = LineBuilderHarness.collect([.lineFeed])
        #expect(lines.count == 1)
        #expect(lines[0].text.isEmpty)
        #expect(lines[0].runs.isEmpty)
    }
}

// MARK: - Styling

@Suite("LineBuilder — styling")
struct LineBuilderStylingTests {
    @Test("Single non-default styled run covers the whole line")
    func singleStyledRun() {
        let bold = StyleAttributes(bold: true)
        let lines = LineBuilderHarness.collect([
            .text("hello", bold),
            .lineFeed
        ])
        #expect(lines.count == 1)
        #expect(lines[0].text == "hello")
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 0..<5, style: bold)
        ])
    }

    @Test("Default prefix and suffix bracket a styled middle run")
    func mixedDefaultAndStyled() {
        let bold = StyleAttributes(bold: true)
        let lines = LineBuilderHarness.collect([
            .text("plain ", .default),
            .text("bold", bold),
            .text(" plain", .default),
            .lineFeed
        ])
        // "plain " (6) + "bold" (4) + " plain" (6) = 16
        #expect(lines.count == 1)
        #expect(lines[0].text == "plain bold plain")
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 6..<10, style: bold)
        ])
    }

    @Test("Two adjacent different styled runs")
    func twoAdjacentStyledRuns() {
        let bold = StyleAttributes(bold: true)
        let italic = StyleAttributes(italic: true)
        let lines = LineBuilderHarness.collect([
            .text("bb", bold),
            .text("ii", italic),
            .lineFeed
        ])
        #expect(lines[0].text == "bbii")
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 0..<2, style: bold),
            StyledRun(utf16Range: 2..<4, style: italic)
        ])
    }

    @Test("Same style across multiple text events produces a single run")
    func sameStyleAcrossEvents() {
        let bold = StyleAttributes(bold: true)
        let lines = LineBuilderHarness.collect([
            .text("foo", bold),
            .text("bar", bold),
            .lineFeed
        ])
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 0..<6, style: bold)
        ])
    }

    @Test("Style persists across LF boundaries")
    func stylePersistsAcrossLF() {
        let bold = StyleAttributes(bold: true)
        let lines = LineBuilderHarness.collect([
            .text("first", bold),
            .lineFeed,
            .text("second", bold),
            .lineFeed
        ])
        #expect(lines[0].runs == [StyledRun(utf16Range: 0..<5, style: bold)])
        #expect(lines[1].runs == [StyledRun(utf16Range: 0..<6, style: bold)])
    }

    @Test("Pure default-styled text has no runs")
    func pureDefaultHasNoRuns() {
        let lines = LineBuilderHarness.collect([
            .text("default text", .default),
            .lineFeed
        ])
        #expect(lines[0].runs.isEmpty)
    }

    @Test("Three styles in one line produces three runs")
    func threeStylesProduceThreeRuns() {
        let red = StyleAttributes(foreground: .named(.red))
        let green = StyleAttributes(foreground: .named(.green))
        let blue = StyleAttributes(foreground: .named(.blue))
        let lines = LineBuilderHarness.collect([
            .text("R", red),
            .text("G", green),
            .text("B", blue),
            .lineFeed
        ])
        #expect(lines[0].text == "RGB")
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 0..<1, style: red),
            StyledRun(utf16Range: 1..<2, style: green),
            StyledRun(utf16Range: 2..<3, style: blue)
        ])
    }
}

// MARK: - UTF-16

@Suite("LineBuilder — UTF-16 ranges")
struct LineBuilderUTF16Tests {
    @Test("Emoji counts two UTF-16 code units")
    func utf16ForEmoji() {
        let bold = StyleAttributes(bold: true)
        let lines = LineBuilderHarness.collect([
            .text("👋", bold),
            .lineFeed
        ])
        #expect(lines[0].text == "👋")
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 0..<2, style: bold)
        ])
    }

    @Test("ASCII + emoji + ASCII gives correct UTF-16 offsets")
    func utf16ForMixedAsciiAndEmoji() {
        let bold = StyleAttributes(bold: true)
        let lines = LineBuilderHarness.collect([
            .text("A", .default),
            .text("👋", bold),
            .text("B", .default),
            .lineFeed
        ])
        #expect(lines[0].text == "A👋B")
        #expect(lines[0].text.utf16.count == 4)
        #expect(lines[0].runs == [
            StyledRun(utf16Range: 1..<3, style: bold)
        ])
    }
}

// MARK: - Non-line events

@Suite("LineBuilder — control events")
struct LineBuilderControlEventTests {
    @Test("Bell, tab, backspace, otherControl, unhandledCSI do not affect content")
    func controlEventsIgnored() {
        let lines = LineBuilderHarness.collect([
            .text("A", .default),
            .bell,
            .tab,
            .backspace,
            .otherControl(0x0C),
            .unhandledCSI(final: 0x4A, parameters: [2]),
            .text("B", .default),
            .lineFeed
        ])
        #expect(lines.count == 1)
        #expect(lines[0].text == "AB")
    }

    @Test("Carriage return is currently ignored (Aardwolf emits CRLF; LF does the work)")
    func carriageReturnIgnored() {
        let lines = LineBuilderHarness.collect([
            .text("A", .default),
            .carriageReturn,
            .text("B", .default),
            .lineFeed
        ])
        #expect(lines.map(\.text) == ["AB"])
    }
}

// MARK: - Lifecycle

@Suite("LineBuilder — lifecycle")
struct LineBuilderLifecycleTests {
    @Test("reset() clears in-progress state and styling")
    func resetClears() {
        var builder = LineBuilder()
        builder.consume(.text("partial", StyleAttributes(bold: true))) { _ in }
        builder.reset()

        var emitted: [Line] = []
        builder.consume(.text("fresh", .default)) { emitted.append($0) }
        builder.consume(.lineFeed) { emitted.append($0) }
        #expect(emitted.count == 1)
        #expect(emitted[0].text == "fresh")
        #expect(emitted[0].runs.isEmpty)
    }

    @Test("flush() with no pending content emits nothing")
    func flushIdle() {
        var builder = LineBuilder()
        var lines: [Line] = []
        builder.flush { lines.append($0) }
        #expect(lines.isEmpty)
    }
}

// MARK: - Pipeline integration

@Suite("LineBuilder — pipeline integration")
struct LineBuilderPipelineTests {
    @Test("Bytes → ANSIParser → LineBuilder produces expected lines")
    func bytesThroughANSIAndBuilder() {
        let input = "Hello\n\u{1B}[1mWorld\u{1B}[0m\nfin"
        let bytes = Array(input.utf8)

        var parser = ANSIParser()
        var builder = LineBuilder()
        var lines: [Line] = []

        parser.process(bytes) { event in
            builder.consume(event) { lines.append($0) }
        }
        parser.flush { event in
            builder.consume(event) { lines.append($0) }
        }
        builder.flush { lines.append($0) }

        let bold = StyleAttributes(bold: true)
        #expect(lines.count == 3)
        #expect(lines.map(\.text) == ["Hello", "World", "fin"])
        #expect(lines[0].runs.isEmpty)
        #expect(lines[1].runs == [StyledRun(utf16Range: 0..<5, style: bold)])
        #expect(lines[2].runs.isEmpty)
    }

    @Test("Bytes → ANSI → LineBuilder → ScrollbackStore end-to-end")
    func bytesAllTheWayToScrollback() async {
        let input = "alpha\n\u{1B}[31mbeta\u{1B}[0m\ngamma\n"
        let bytes = Array(input.utf8)
        let store = ScrollbackStore()

        var parser = ANSIParser()
        var builder = LineBuilder()
        var emitted: [Line] = []
        parser.process(bytes) { event in
            builder.consume(event) { emitted.append($0) }
        }
        parser.flush { event in
            builder.consume(event) { emitted.append($0) }
        }
        builder.flush { emitted.append($0) }

        for line in emitted {
            await store.append(line)
        }

        let stored = await store.snapshot()
        #expect(stored.map(\.text) == ["alpha", "beta", "gamma"])
        // Store assigned monotonic IDs starting at 0.
        #expect(stored.map(\.id) == [LineID(0), LineID(1), LineID(2)])
        let red = StyleAttributes(foreground: .named(.red))
        #expect(stored[1].runs == [StyledRun(utf16Range: 0..<4, style: red)])
    }
}
