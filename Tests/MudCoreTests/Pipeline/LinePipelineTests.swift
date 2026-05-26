@testable import MudCore
import Testing

@Suite("LinePipeline — plain bytes")
struct LinePipelinePlainTests {
    @Test("Empty input produces no lines and no responses")
    func emptyInput() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume([])
        #expect(output.lines.isEmpty)
        #expect(output.responses.isEmpty)
        #expect(!output.activatedCompression)
    }

    @Test("Plain ASCII text becomes a Line at LF")
    func plainText() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume(Array("Hello!\n".utf8))
        #expect(output.lines.map(\.text) == ["Hello!"])
    }

    @Test("ANSI-styled text produces styled runs")
    func ansiStyledText() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume(
            Array("\u{1B}[31mRed\u{1B}[0m\n".utf8)
        )
        #expect(output.lines.count == 1)
        #expect(output.lines[0].text == "Red")
        #expect(output.lines[0].runs == [
            StyledRun(
                utf16Range: 0..<3,
                style: StyleAttributes(foreground: .named(.red))
            )
        ])
    }

    @Test("Bytes split across multiple consume() calls assemble correctly")
    func splitChunks() throws {
        var pipeline = LinePipeline()
        let part1 = try pipeline.consume(Array("part1 ".utf8))
        let part2 = try pipeline.consume(Array("part2\n".utf8))
        #expect(part1.lines.isEmpty)
        #expect(part2.lines.map(\.text) == ["part1 part2"])
    }
}

@Suite("LinePipeline — telnet negotiation")
struct LinePipelineNegotiationTests {
    @Test("WILL MCCP2 is accepted: DO COMPRESS2 in responses")
    func willMCCP2Accepted() throws {
        var pipeline = LinePipeline()
        let willMCCP2: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.mccp2
        ]
        let output = try pipeline.consume(willMCCP2)
        #expect(output.responses == [
            [TelnetCommand.iac, TelnetCommand.do, TelnetOption.mccp2]
        ])
    }

    @Test("WILL GMCP is accepted: DO GMCP in responses and enabledGMCP set")
    func willGMCPAccepted() throws {
        var pipeline = LinePipeline()
        let willGMCP: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.gmcp
        ]
        let output = try pipeline.consume(willGMCP)
        #expect(output.responses == [
            [TelnetCommand.iac, TelnetCommand.do, TelnetOption.gmcp]
        ])
        #expect(output.enabledGMCP)
    }

    @Test("WILL MXP is refused: DONT MXP in responses")
    func willMXPRefused() throws {
        var pipeline = LinePipeline()
        let willMXP: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.mxp
        ]
        let output = try pipeline.consume(willMXP)
        #expect(output.responses == [
            [TelnetCommand.iac, TelnetCommand.dont, TelnetOption.mxp]
        ])
        #expect(!output.enabledGMCP)
    }

    @Test("GMCP subnegotiation is decoded into output.gmcp")
    func gmcpSubnegotiationDecoded() throws {
        var pipeline = LinePipeline()
        let payload = Array(#"Char.Vitals {"hp":1234,"mana":900,"moves":500}"#.utf8)
        var bytes: [UInt8] = [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp]
        bytes += payload
        bytes += [TelnetCommand.iac, TelnetCommand.se]
        let output = try pipeline.consume(bytes)
        #expect(output.gmcp.count == 1)
        #expect(output.gmcp.first?.package == "Char.Vitals")
        #expect(output.gmcp.first?.json == #"{"hp":1234,"mana":900,"moves":500}"#)
    }

    @Test("DO TTYPE is refused: WONT TTYPE in responses")
    func doTTYPERefused() throws {
        var pipeline = LinePipeline()
        let doTTYPE: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.do, TelnetOption.terminalType
        ]
        let output = try pipeline.consume(doTTYPE)
        #expect(output.responses == [
            [TelnetCommand.iac, TelnetCommand.wont, TelnetOption.terminalType]
        ])
    }
}

@Suite("LinePipeline — MCCP2")
struct LinePipelineMCCP2Tests {
    private static let mccp2Start: [UInt8] = [
        TelnetCommand.iac, TelnetCommand.sb, TelnetOption.mccp2,
        TelnetCommand.iac, TelnetCommand.se
    ]

    @Test("Marker activates compression and remainder of chunk is inflated")
    func markerActivatesAndInflatesRemainder() throws {
        var pipeline = LinePipeline()

        let deflater = try Deflater()
        let compressed = try deflater.compress(
            Array("after compression\n".utf8)
        )
        var wire = Self.mccp2Start
        wire.append(contentsOf: compressed)

        let output = try pipeline.consume(wire)
        #expect(pipeline.isCompressionActive)
        #expect(output.activatedCompression)
        #expect(output.lines.map(\.text) == ["after compression"])
    }

    @Test("Plain text before the marker is processed plainly")
    func plainBeforeMarker() throws {
        var pipeline = LinePipeline()

        var wire = Array("Welcome!\n".utf8)
        wire.append(contentsOf: Self.mccp2Start)
        let deflater = try Deflater()
        try wire.append(contentsOf: deflater.compress(Array("After.\n".utf8)))

        let output = try pipeline.consume(wire)
        #expect(output.lines.map(\.text) == ["Welcome!", "After."])
    }

    @Test("MCCP2 activation persists across consume() calls")
    func compressionPersistsAcrossCalls() throws {
        var pipeline = LinePipeline()
        _ = try pipeline.consume(Self.mccp2Start)
        #expect(pipeline.isCompressionActive)

        let deflater = try Deflater()
        let compressed = try deflater.compress(Array("second chunk\n".utf8))
        let output = try pipeline.consume(compressed)
        #expect(output.lines.map(\.text) == ["second chunk"])
    }
}

@Suite("LinePipeline — lifecycle")
struct LinePipelineLifecycleTests {
    @Test("flush() emits a trailing partial line")
    func flushEmitsPartial() throws {
        var pipeline = LinePipeline()
        _ = try pipeline.consume(Array("partial".utf8))
        let trailing = pipeline.flush()
        #expect(trailing.map(\.text) == ["partial"])
    }

    @Test("reset() clears parser + inflater state")
    func resetClearsState() throws {
        var pipeline = LinePipeline()
        _ = try pipeline.consume(Self.mccp2StartBytes)
        #expect(pipeline.isCompressionActive)

        pipeline.reset()
        #expect(!pipeline.isCompressionActive)

        // After reset, plain bytes are processed as plain again.
        let output = try pipeline.consume(Array("plain\n".utf8))
        #expect(output.lines.map(\.text) == ["plain"])
    }

    private static let mccp2StartBytes: [UInt8] = [
        TelnetCommand.iac, TelnetCommand.sb, TelnetOption.mccp2,
        TelnetCommand.iac, TelnetCommand.se
    ]
}

@Suite("LinePipeline — server ECHO toggle")
struct LinePipelineEchoTests {
    @Test("WILL ECHO sets serverWillEcho true; WONT ECHO sets it false")
    func echoToggle() throws {
        var pipeline = LinePipeline()
        let iac = TelnetCommand.iac
        // IAC WILL ECHO (option 1) → server is taking over echo.
        let will = try pipeline.consume([iac, TelnetCommand.will, TelnetOption.echo])
        #expect(will.serverWillEcho == true)
        // IAC WONT ECHO → server stops echoing.
        let wont = try pipeline.consume([iac, TelnetCommand.wont, TelnetOption.echo])
        #expect(wont.serverWillEcho == false)
    }

    @Test("Unrelated negotiation leaves serverWillEcho nil")
    func unrelatedNegotiation() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume([TelnetCommand.iac, TelnetCommand.will, TelnetOption.gmcp])
        #expect(output.serverWillEcho == nil)
    }
}

@Suite("LinePipeline — GA prompt boundary")
struct LinePipelineGoAheadTests {
    private func ga() -> [UInt8] {
        [TelnetCommand.iac, TelnetCommand.ga]
    }

    @Test("IAC GA flushes a newline-less prompt as its own Line")
    func gaFlushesPrompt() throws {
        var pipeline = LinePipeline()
        // A prompt with no trailing LF: without GA it would sit pending.
        let output = try pipeline.consume(Array("<100hp>".utf8) + ga())
        #expect(output.lines.map(\.text) == ["<100hp>"])
        #expect(pipeline.pendingLineText.isEmpty)
    }

    @Test("Without GA the prompt stays pending (baseline)")
    func noGaKeepsPending() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume(Array("<100hp>".utf8))
        #expect(output.lines.isEmpty)
        #expect(pipeline.pendingLineText == "<100hp>")
    }

    @Test("GA with nothing pending emits no spurious empty line")
    func gaNoPendingNoLine() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume(ga())
        #expect(output.lines.isEmpty)
    }

    @Test("GA separates the prompt from the following server line (the fix)")
    func gaSeparatesPromptFromNextLine() throws {
        var pipeline = LinePipeline()
        // Prompt, GA, then a spontaneous line. The line must NOT glue onto the
        // prompt — it arrives as its own anchored-trigger-matchable Line.
        let bytes = Array("<100hp>".utf8) + ga() + Array("You tell the group 'hi'\n".utf8)
        let output = try pipeline.consume(bytes)
        #expect(output.lines.map(\.text) == ["<100hp>", "You tell the group 'hi'"])
    }

    @Test("GA preserves the pending prompt's ANSI styling")
    func gaPreservesStyling() throws {
        var pipeline = LinePipeline()
        let output = try pipeline.consume(Array("\u{1B}[31m<hp>\u{1B}[0m".utf8) + ga())
        #expect(output.lines.count == 1)
        #expect(output.lines[0].text == "<hp>")
        #expect(output.lines[0].runs == [
            StyledRun(utf16Range: 0..<4, style: StyleAttributes(foreground: .named(.red)))
        ])
    }
}

@Suite("SessionController — input echo line")
struct SessionControllerInputEchoTests {
    @Test("A typed command echoes as a dimmed line")
    func dimmedEcho() {
        let line = SessionController.inputEchoLine("north")
        #expect(line.text == "north")
        #expect(line.runs.count == 1)
        #expect(line.runs[0].style.foreground == .rgb(red: 140, green: 140, blue: 140))
    }
}
