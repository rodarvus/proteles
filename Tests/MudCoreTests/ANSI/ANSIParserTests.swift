@testable import MudCore
import Testing

// MARK: - Plain text

@Suite("ANSIParser — plain text")
struct ANSIParserPlainTextTests {
    @Test("ASCII passes through as a single text event")
    func plainAscii() {
        let events = ANSIParserHarness.collect("Hello")
        #expect(events == [.text("Hello", .default)])
    }

    @Test("LF splits text into two events")
    func lfSplitsText() {
        let events = ANSIParserHarness.collect("Hi\nthere")
        #expect(events == [
            .text("Hi", .default),
            .lineFeed,
            .text("there", .default)
        ])
    }

    @Test("CRLF emits CR then LF")
    func crlf() {
        let events = ANSIParserHarness.collect("A\r\nB")
        #expect(events == [
            .text("A", .default),
            .carriageReturn,
            .lineFeed,
            .text("B", .default)
        ])
    }

    @Test("Tab and bell pass through as events")
    func tabAndBell() {
        let events = ANSIParserHarness.collect("A\tB\u{07}C")
        #expect(events == [
            .text("A", .default),
            .tab,
            .text("B", .default),
            .bell,
            .text("C", .default)
        ])
    }

    @Test("Other C0 controls emit otherControl")
    func otherC0Controls() {
        // 0x00 NUL, 0x0C FF, 0x7F DEL
        let events = ANSIParserHarness.collectBytes([
            0x41, 0x00, 0x42, 0x0C, 0x43, 0x7F, 0x44
        ])
        #expect(events == [
            .text("A", .default),
            .otherControl(0x00),
            .text("B", .default),
            .otherControl(0x0C),
            .text("C", .default),
            .otherControl(0x7F),
            .text("D", .default)
        ])
    }
}

// MARK: - UTF-8

@Suite("ANSIParser — UTF-8")
struct ANSIParserUTF8Tests {
    @Test("Multi-byte UTF-8 character decodes correctly")
    func utf8MultiByte() {
        let events = ANSIParserHarness.collect("café")
        #expect(events == [.text("café", .default)])
    }

    @Test("UTF-8 sequence split across calls reassembles")
    func utf8SplitAcrossCalls() {
        var parser = ANSIParser()
        var events: [ANSIEvent] = []
        // 'é' is 0xC3 0xA9 in UTF-8.
        parser.process([0xC3]) { events.append($0) }
        parser.flush { events.append($0) }
        #expect(events.isEmpty)

        parser.process([0xA9]) { events.append($0) }
        parser.flush { events.append($0) }
        #expect(events == [.text("é", .default)])
    }

    @Test("Three-byte UTF-8 split at every internal boundary")
    func threeByteUTF8SplitEverywhere() {
        // '€' (U+20AC) → 0xE2 0x82 0xAC
        let bytes: [UInt8] = [0xE2, 0x82, 0xAC]
        var parser = ANSIParser()
        var events: [ANSIEvent] = []
        for byte in bytes {
            parser.process([byte]) { events.append($0) }
        }
        parser.flush { events.append($0) }
        #expect(events == [.text("€", .default)])
    }
}

// MARK: - SGR styling

@Suite("ANSIParser — SGR styling")
struct ANSIParserSGRTests {
    @Test("ESC[0m reset emits nothing")
    func sgrReset() {
        let events = ANSIParserHarness.collect("\u{1B}[0m")
        #expect(events.isEmpty)
    }

    @Test("Bold then text")
    func boldThenText() {
        let events = ANSIParserHarness.collect("\u{1B}[1mhi")
        #expect(events == [.text("hi", StyleAttributes(bold: true))])
    }

    @Test("SGR with empty params defaults to reset")
    func emptyParamsDefaultsToReset() {
        var parser = ANSIParser()
        parser.process(Array("\u{1B}[1mX".utf8)) { _ in }
        #expect(parser.currentStyle.bold)

        var events: [ANSIEvent] = []
        parser.process(Array("\u{1B}[mY".utf8)) { events.append($0) }
        parser.flush { events.append($0) }
        #expect(events.contains(.text("Y", .default)))
        #expect(!parser.currentStyle.bold)
    }

    @Test("Multiple SGR codes combine in one sequence")
    func multipleCodesCombined() {
        let events = ANSIParserHarness.collect("\u{1B}[1;31;4mwarn")
        let expected = StyleAttributes(
            foreground: .named(.red),
            bold: true,
            underline: true
        )
        #expect(events == [.text("warn", expected)])
    }

    @Test("Style change splits text into runs")
    func styleChangeSplitsText() {
        let events = ANSIParserHarness.collect(
            "plain\u{1B}[1mbold\u{1B}[0mplain"
        )
        #expect(events == [
            .text("plain", .default),
            .text("bold", StyleAttributes(bold: true)),
            .text("plain", .default)
        ])
    }

    @Test("SGR 22 resets both bold and dim")
    func sgr22ResetsBoldAndDim() {
        var parser = ANSIParser()
        parser.process(Array("\u{1B}[1;2mA".utf8)) { _ in }
        #expect(parser.currentStyle.bold)
        #expect(parser.currentStyle.dim)

        parser.process(Array("\u{1B}[22m".utf8)) { _ in }
        #expect(!parser.currentStyle.bold)
        #expect(!parser.currentStyle.dim)
    }

    @Test("Individual resets: 23, 24, 27, 29")
    func individualResets() {
        var parser = ANSIParser()
        parser.process(Array("\u{1B}[3;4;7;9m".utf8)) { _ in }
        #expect(parser.currentStyle.italic)
        #expect(parser.currentStyle.underline)
        #expect(parser.currentStyle.reverse)
        #expect(parser.currentStyle.strikethrough)

        parser.process(Array("\u{1B}[23m".utf8)) { _ in }
        #expect(!parser.currentStyle.italic)
        parser.process(Array("\u{1B}[24m".utf8)) { _ in }
        #expect(!parser.currentStyle.underline)
        parser.process(Array("\u{1B}[27m".utf8)) { _ in }
        #expect(!parser.currentStyle.reverse)
        parser.process(Array("\u{1B}[29m".utf8)) { _ in }
        #expect(!parser.currentStyle.strikethrough)
    }
}

@Suite("ANSIParser — SGR colours")
struct ANSIParserSGRColorTests {
    @Test("SGR 30–37 produce named foreground colours")
    func sgr30to37() {
        for (offset, color) in NamedColor.allCases.enumerated() {
            let sgr = "\u{1B}[\(30 + offset)mX\u{1B}[0m"
            let events = ANSIParserHarness.collect(sgr)
            #expect(
                events == [.text("X", StyleAttributes(foreground: .named(color)))],
                "for SGR \(30 + offset)"
            )
        }
    }

    @Test("SGR 40–47 produce named background colours")
    func sgr40to47() {
        for (offset, color) in NamedColor.allCases.enumerated() {
            let sgr = "\u{1B}[\(40 + offset)mX\u{1B}[0m"
            let events = ANSIParserHarness.collect(sgr)
            #expect(
                events == [.text("X", StyleAttributes(background: .named(color)))],
                "for SGR \(40 + offset)"
            )
        }
    }

    @Test("SGR 90–97 produce bright named foreground colours")
    func sgr90to97() {
        for (offset, color) in NamedColor.allCases.enumerated() {
            let sgr = "\u{1B}[\(90 + offset)mY"
            let events = ANSIParserHarness.collect(sgr)
            let expected = StyleAttributes(foreground: .brightNamed(color))
            #expect(events == [.text("Y", expected)], "for SGR \(90 + offset)")
        }
    }

    @Test("SGR 100–107 produce bright named background colours")
    func sgr100to107() {
        for (offset, color) in NamedColor.allCases.enumerated() {
            let sgr = "\u{1B}[\(100 + offset)mY"
            let events = ANSIParserHarness.collect(sgr)
            let expected = StyleAttributes(background: .brightNamed(color))
            #expect(events == [.text("Y", expected)], "for SGR \(100 + offset)")
        }
    }

    @Test("SGR 38;5;N (8-bit palette foreground)")
    func sgr38_5_N() {
        let events = ANSIParserHarness.collect("\u{1B}[38;5;196mR")
        #expect(events == [.text("R", StyleAttributes(foreground: .palette(196)))])
    }

    @Test("SGR 48;5;N (8-bit palette background)")
    func sgr48_5_N() {
        let events = ANSIParserHarness.collect("\u{1B}[48;5;21mB")
        #expect(events == [.text("B", StyleAttributes(background: .palette(21)))])
    }

    @Test("SGR 38;2;R;G;B (24-bit RGB foreground)")
    func sgr38_2_RGB() {
        let events = ANSIParserHarness.collect("\u{1B}[38;2;255;128;0mO")
        let expected = StyleAttributes(
            foreground: .rgb(red: 255, green: 128, blue: 0)
        )
        #expect(events == [.text("O", expected)])
    }

    @Test("SGR 48;2;R;G;B (24-bit RGB background)")
    func sgr48_2_RGB() {
        let events = ANSIParserHarness.collect("\u{1B}[48;2;0;0;128mD")
        let expected = StyleAttributes(
            background: .rgb(red: 0, green: 0, blue: 128)
        )
        #expect(events == [.text("D", expected)])
    }

    @Test("SGR 39 / 49 reset fg / bg to default")
    func sgr39_49DefaultColors() {
        var parser = ANSIParser()
        parser.process(Array("\u{1B}[31;41m".utf8)) { _ in }
        #expect(parser.currentStyle.foreground == .named(.red))
        #expect(parser.currentStyle.background == .named(.red))

        parser.process(Array("\u{1B}[39m".utf8)) { _ in }
        #expect(parser.currentStyle.foreground == nil)
        #expect(parser.currentStyle.background == .named(.red))

        parser.process(Array("\u{1B}[49m".utf8)) { _ in }
        #expect(parser.currentStyle.background == nil)
    }

    @Test("Combined: bold + bright fg + bg in one sequence")
    func combinedBoldBrightFgBg() {
        let events = ANSIParserHarness.collect("\u{1B}[1;91;44mtxt")
        let expected = StyleAttributes(
            foreground: .brightNamed(.red),
            background: .named(.blue),
            bold: true
        )
        #expect(events == [.text("txt", expected)])
    }
}

// MARK: - Partial / streamed

@Suite("ANSIParser — partial input")
struct ANSIParserPartialInputTests {
    @Test("CSI split across chunks reassembles")
    func csiSplitAcrossChunks() {
        var parser = ANSIParser()
        var events: [ANSIEvent] = []
        parser.process(Array("X\u{1B}[".utf8)) { events.append($0) }
        parser.process(Array("1m".utf8)) { events.append($0) }
        parser.process(Array("Y".utf8)) { events.append($0) }
        parser.flush { events.append($0) }
        #expect(events == [
            .text("X", .default),
            .text("Y", StyleAttributes(bold: true))
        ])
    }

    @Test("Long CSI parameter accumulates across calls")
    func longCSISplit() {
        var parser = ANSIParser()
        var events: [ANSIEvent] = []
        parser.process(Array("\u{1B}[38;".utf8)) { events.append($0) }
        parser.process(Array("2;".utf8)) { events.append($0) }
        parser.process(Array("255;128;0".utf8)) { events.append($0) }
        parser.process(Array("mO".utf8)) { events.append($0) }
        parser.flush { events.append($0) }
        let expected = StyleAttributes(
            foreground: .rgb(red: 255, green: 128, blue: 0)
        )
        #expect(events == [.text("O", expected)])
    }
}

// MARK: - Unhandled / malformed

@Suite("ANSIParser — unhandled CSI & malformed")
struct ANSIParserUnhandledTests {
    @Test("Unknown CSI emits unhandledCSI")
    func unknownCSI() {
        let events = ANSIParserHarness.collect("\u{1B}[2J")
        #expect(events == [.unhandledCSI(final: 0x4A, parameters: [2])])
    }

    @Test("ESC not followed by '[' returns to ground without crashing")
    func loneEscape() {
        let events = ANSIParserHarness.collect("A\u{1B}ZB")
        // ESC is consumed; the byte after ESC (here 'Z') is also consumed
        // when we leave .escape; the parser is back in ground for 'B'.
        #expect(events.contains(.text("A", .default)))
        #expect(events.contains(.text("B", .default)))
    }

    @Test("Out-of-range CSI byte aborts and returns to ground")
    func outOfRangeCSIAborts() {
        // ESC[1<NUL>m A — the NUL (0x00) is outside any CSI byte range
        // and aborts the in-progress CSI. The 'm' and 'A' that follow
        // are then plain text. The point of this test is that the
        // out-of-range byte does not panic, infinite-loop, or swallow
        // subsequent input.
        let bytes: [UInt8] = [
            0x1B, 0x5B, 0x31, 0x00, 0x6D, 0x41
        ]
        let events = ANSIParserHarness.collectBytes(bytes)
        #expect(events == [.text("mA", .default)])
    }
}

// MARK: - Lifecycle

@Suite("ANSIParser — lifecycle")
struct ANSIParserLifecycleTests {
    @Test("reset() clears style and pending state")
    func resetClears() {
        var parser = ANSIParser()
        parser.process(Array("\u{1B}[1m".utf8)) { _ in }
        #expect(parser.currentStyle.bold)

        parser.reset()
        #expect(!parser.currentStyle.bold)

        var events: [ANSIEvent] = []
        parser.process(Array("X".utf8)) { events.append($0) }
        parser.flush { events.append($0) }
        #expect(events == [.text("X", .default)])
    }

    @Test("flush() with no pending text emits nothing")
    func flushIdle() {
        var parser = ANSIParser()
        var events: [ANSIEvent] = []
        parser.flush { events.append($0) }
        #expect(events.isEmpty)
    }
}

// MARK: - Harness

enum ANSIParserHarness {
    static func collect(_ string: String) -> [ANSIEvent] {
        collectBytes(Array(string.utf8))
    }

    static func collectBytes(_ bytes: [UInt8]) -> [ANSIEvent] {
        var parser = ANSIParser()
        var events: [ANSIEvent] = []
        parser.process(bytes) { events.append($0) }
        parser.flush { events.append($0) }
        return events
    }
}
