import Foundation
@testable import MudCore
import Testing

/// `OutputLineBuffer` — the pure backing for `GetLineCount`/`GetLinesInBufferCount`/
/// `GetLineInfo`/`GetStyleInfo`/`GetRecentLines`. Semantics ported from
/// MUSHclient `methods_info.cpp` (1-indexed buffer position, out-of-range → nil,
/// UTF-8 byte lengths/columns).
@Suite("OutputLineBuffer — line/style info")
struct OutputLineBufferTests {
    private func line(
        _ id: UInt64,
        _ text: String,
        runs: [StyledRun] = [],
        kind: OutputLineKind = .mud,
        at seconds: TimeInterval = 1000
    ) -> BufferedLine {
        let timestamp = Date(timeIntervalSince1970: seconds)
        return BufferedLine(id: id, timestamp: timestamp, text: text, runs: runs, kind: kind)
    }

    @Test("total-received vs buffered count, with bounded eviction")
    func counts() {
        var buffer = OutputLineBuffer(maxLines: 3)
        for index in 1 ... 5 { buffer.append(line(UInt64(index), "line \(index)")) }
        #expect(buffer.lineCount == 5) // running total, never decremented
        #expect(buffer.linesInBuffer == 3) // bounded
        #expect(buffer.lineInfo(1, 1) == .string("line 3")) // oldest two evicted
        #expect(buffer.lineInfo(3, 1) == .string("line 5"))
    }

    @Test("out-of-range line / unknown infotype → nil")
    func bounds() {
        var buffer = OutputLineBuffer()
        buffer.append(line(1, "hello"))
        #expect(buffer.lineInfo(0, 1) == .nil)
        #expect(buffer.lineInfo(2, 1) == .nil)
        #expect(buffer.lineInfo(1, 999) == .nil)
    }

    @Test("lineInfo fields map to MUSHclient infotypes (UTF-8 length, flags, id, elapsed)")
    func lineInfoFields() {
        var buffer = OutputLineBuffer()
        buffer.reset(connectedAt: Date(timeIntervalSince1970: 1000))
        buffer.append(line(42, "caf\u{E9}", kind: .note, at: 1002)) // precomposed é = 2 UTF-8 bytes
        #expect(buffer.lineInfo(1, 1) == .string("caf\u{E9}"))
        #expect(buffer.lineInfo(1, 2) == .number(5)) // 3 ASCII + 2-byte é
        #expect(buffer.lineInfo(1, 4) == .boolean(true)) // note
        #expect(buffer.lineInfo(1, 5) == .boolean(false)) // not user input
        #expect(buffer.lineInfo(1, 9) == .number(1002)) // unix time
        #expect(buffer.lineInfo(1, 10) == .number(43)) // line number (0-based id 42 → 1-based 43)
        #expect(buffer.lineInfo(1, 13) == .number(2)) // elapsed since connect
    }

    @Test("styleInfo: byte offsets on a multi-byte line, colour, flags")
    func styleInfoFields() {
        // "café X": é is 1 UTF-16 unit but 2 UTF-8 bytes; the run covers " X".
        let text = "caf\u{E9} X"
        let run = StyledRun(
            utf16Range: 4 ..< 6,
            style: StyleAttributes(foreground: .brightNamed(.red), bold: true)
        )
        var buffer = OutputLineBuffer()
        buffer.append(line(1, text, runs: [run]))
        #expect(buffer.lineInfo(1, 11) == .number(1)) // style count
        #expect(buffer.styleInfo(1, 1, 1) == .string(" X")) // run text
        #expect(buffer.styleInfo(1, 1, 2) == .number(2)) // run byte length
        #expect(buffer.styleInfo(1, 1, 3) == .number(6)) // start col: "café" = 5 bytes → 5+1
        #expect(buffer.styleInfo(1, 1, 8) == .boolean(true)) // bold
        #expect(buffer.styleInfo(1, 1, 14) == .number(255)) // bright-red COLORREF
        #expect(buffer.styleInfo(1, 1, 15) == .number(0)) // no background → black
        #expect(buffer.styleInfo(1, 2, 1) == .nil) // style out of range
    }

    @Test("styleInfo: hyperlink vs send action")
    func styleInfoLinks() {
        var buffer = OutputLineBuffer()
        let urlRun = StyledRun(
            utf16Range: 0 ..< 3,
            style: .default,
            link: LineLink(action: .openURL("https://x"), hint: "open")
        )
        let cmdRun = StyledRun(
            utf16Range: 3 ..< 6,
            style: .default,
            link: LineLink(action: .sendCommand("north"))
        )
        buffer.append(line(1, "abcdef", runs: [urlRun, cmdRun]))
        #expect(buffer.styleInfo(1, 1, 4) == .number(2)) // hyperlink
        #expect(buffer.styleInfo(1, 1, 5) == .string("https://x"))
        #expect(buffer.styleInfo(1, 1, 6) == .string("open"))
        #expect(buffer.styleInfo(1, 2, 4) == .number(1)) // send to MUD
        #expect(buffer.styleInfo(1, 2, 5) == .string("north"))
    }

    @Test("recentLines joins the last N lines")
    func recent() {
        var buffer = OutputLineBuffer()
        for index in 1 ... 4 { buffer.append(line(UInt64(index), "L\(index)")) }
        #expect(buffer.recentLines(2) == "L3\nL4")
        #expect(buffer.recentLines(99) == "L1\nL2\nL3\nL4")
        #expect(buffer.recentLines(0).isEmpty)
    }
}

/// The same functions reached through the generic compat shim (the plugin path).
@Suite("Output-buffer world functions via the shim")
struct OutputBufferShimTests {
    @Test("GetLineCount / GetLineInfo / GetStyleInfo / GetRecentLines reach the mirror")
    func shim() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim()
        await engine.resetOutputBuffer(connectedAt: Date(timeIntervalSince1970: 1000))
        await engine.recordOutputLine(
            id: 1,
            timestamp: Date(timeIntervalSince1970: 1001),
            text: "hello",
            runs: [],
            kind: .mud
        )
        await engine.recordOutputLine(
            id: 2,
            timestamp: Date(timeIntervalSince1970: 1002),
            text: "world",
            runs: [StyledRun(utf16Range: 0 ..< 5, style: StyleAttributes(foreground: .brightNamed(.red)))],
            kind: .note
        )
        func console(_ code: String, _ expected: String) async {
            #expect(await engine.evaluateConsole(code)
                == [.note(text: "lua: = \(expected)", foreground: "cyan", background: nil)])
        }
        await console("GetLineCount()", "2")
        await console("GetLinesInBufferCount()", "2")
        await console("GetLineInfo(1, 1)", "hello")
        await console("GetLineInfo(2, 4)", "true") // note flag
        await console("GetStyleInfo(2, 1, 14)", "255") // bright-red fg COLORREF
        await console("GetRecentLines(1)", "world")
        await console("GetLineInfo(1).text", "hello") // all-fields table form
    }
}
