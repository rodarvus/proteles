@testable import MudCore
import Testing

@Suite("TelnetProcessor — plain data")
struct TelnetProcessorPlainDataTests {
    @Test("ASCII bytes pass through as data events")
    func plainAsciiPassesThrough() {
        let events = TelnetProcessorHarness.collect([0x68, 0x69])
        #expect(events == [.data(0x68), .data(0x69)])
    }

    @Test("High bytes (non-IAC) pass through")
    func highBytesPassThrough() {
        let events = TelnetProcessorHarness.collect([0x80, 0xFE, 0xC2, 0xA0])
        #expect(events == [.data(0x80), .data(0xFE), .data(0xC2), .data(0xA0)])
    }

    @Test("Empty input emits nothing")
    func emptyInputEmitsNothing() {
        let events = TelnetProcessorHarness.collect([])
        #expect(events.isEmpty)
    }
}

@Suite("TelnetProcessor — IAC escape doubling")
struct TelnetProcessorEscapeDoublingTests {
    @Test("Doubled IAC emits a single 0xFF data byte")
    func doubledIACEscapes() {
        let events = TelnetProcessorHarness.collect([
            TelnetCommand.iac,
            TelnetCommand.iac
        ])
        #expect(events == [.data(0xFF)])
    }

    @Test("Doubled IAC interspersed with text")
    func doubledIACInterspersed() {
        let bytes: [UInt8] = [
            0x41,
            TelnetCommand.iac,
            TelnetCommand.iac,
            0x42
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [.data(0x41), .data(0xFF), .data(0x42)])
    }

    @Test("Doubled IAC at chunk boundary")
    func doubledIACAtChunkBoundary() {
        var processor = TelnetProcessor()
        var events: [TelnetEvent] = []
        processor.process([0x41, TelnetCommand.iac]) { events.append($0) }
        #expect(events == [.data(0x41)])
        processor.process([TelnetCommand.iac, 0x42]) { events.append($0) }
        #expect(events == [.data(0x41), .data(0xFF), .data(0x42)])
    }
}

@Suite("TelnetProcessor — standalone commands")
struct TelnetProcessorCommandTests {
    @Test("NOP is emitted")
    func nop() {
        let events = TelnetProcessorHarness.collect([
            TelnetCommand.iac,
            TelnetCommand.nop
        ])
        #expect(events == [.command(TelnetCommand.nop)])
    }

    @Test("Multiple standalone commands emitted in order")
    func multipleCommands() {
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.nop,
            TelnetCommand.iac, TelnetCommand.ga,
            TelnetCommand.iac, TelnetCommand.ayt
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .command(TelnetCommand.nop),
            .command(TelnetCommand.ga),
            .command(TelnetCommand.ayt)
        ])
    }

    @Test("Data and commands interleave correctly")
    func dataAndCommandsInterleave() {
        let bytes: [UInt8] = [
            0x41,
            TelnetCommand.iac, TelnetCommand.ga,
            0x42
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .data(0x41),
            .command(TelnetCommand.ga),
            .data(0x42)
        ])
    }
}

@Suite("TelnetProcessor — option negotiation")
struct TelnetProcessorNegotiationTests {
    @Test("WILL ECHO emits the negotiation")
    func willEcho() {
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.echo
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [.negotiate(verb: .will, option: TelnetOption.echo)])
    }

    @Test("All four verbs round-trip for one option")
    func allFourVerbs() {
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.do, TelnetOption.gmcp,
            TelnetCommand.iac, TelnetCommand.dont, TelnetOption.gmcp,
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.gmcp,
            TelnetCommand.iac, TelnetCommand.wont, TelnetOption.gmcp
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .negotiate(verb: .do, option: TelnetOption.gmcp),
            .negotiate(verb: .dont, option: TelnetOption.gmcp),
            .negotiate(verb: .will, option: TelnetOption.gmcp),
            .negotiate(verb: .wont, option: TelnetOption.gmcp)
        ])
    }

    @Test("Negotiation split across two chunks")
    func negotiationSplitAcrossChunks() {
        var processor = TelnetProcessor()
        var events: [TelnetEvent] = []
        processor.process([TelnetCommand.iac, TelnetCommand.will]) {
            events.append($0)
        }
        #expect(events.isEmpty)
        processor.process([TelnetOption.gmcp]) { events.append($0) }
        #expect(events == [.negotiate(verb: .will, option: TelnetOption.gmcp)])
    }

    @Test("Negotiation split into three single-byte chunks")
    func negotiationSplitByteByByte() {
        var processor = TelnetProcessor()
        var events: [TelnetEvent] = []
        for byte: UInt8 in [
            TelnetCommand.iac,
            TelnetCommand.do,
            TelnetOption.mccp2
        ] {
            processor.process([byte]) { events.append($0) }
        }
        #expect(events == [.negotiate(verb: .do, option: TelnetOption.mccp2)])
    }
}

@Suite("TelnetProcessor — subnegotiation")
struct TelnetProcessorSubnegotiationTests {
    @Test("Empty subnegotiation")
    func emptySubnegotiation() {
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.mccp2,
            TelnetCommand.iac, TelnetCommand.se
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [.subnegotiation(option: TelnetOption.mccp2, payload: [])])
    }

    @Test("Subnegotiation with ASCII payload")
    func subnegotiationWithPayload() {
        let payload: [UInt8] = Array("hello".utf8)
        var bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp
        ]
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .subnegotiation(option: TelnetOption.gmcp, payload: payload)
        ])
    }

    @Test("IAC IAC inside subneg payload yields a single 0xFF")
    func iacIACInsideSubneg() {
        var bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp, 0x41
        ]
        bytes.append(contentsOf: [
            TelnetCommand.iac, TelnetCommand.iac, 0x42
        ])
        bytes.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .subnegotiation(
                option: TelnetOption.gmcp,
                payload: [0x41, 0xFF, 0x42]
            )
        ])
    }

    @Test("Subnegotiation split byte-by-byte")
    func subnegotiationSplitByteByByte() {
        var bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp
        ]
        bytes.append(contentsOf: [0x41, 0x42])
        bytes.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])

        var processor = TelnetProcessor()
        var events: [TelnetEvent] = []
        for byte in bytes {
            processor.process([byte]) { events.append($0) }
        }
        #expect(events == [
            .subnegotiation(option: TelnetOption.gmcp, payload: [0x41, 0x42])
        ])
    }
}

@Suite("TelnetProcessor — malformed recovery")
struct TelnetProcessorMalformedTests {
    @Test("IAC + bogus byte in subneg terminates and reprocesses")
    func malformedIACInsideSubneg() {
        // SB GMCP 'A' 'B' IAC 0x99 'C' IAC SE
        // Expect: subneg flushed with [0x41, 0x42], 0x99 reprocessed as
        // data, 0x43 as data, IAC SE re-entered with SE as command.
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp,
            0x41, 0x42,
            TelnetCommand.iac, 0x99,
            0x43,
            TelnetCommand.iac, TelnetCommand.se
        ]
        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .subnegotiation(option: TelnetOption.gmcp, payload: [0x41, 0x42]),
            .data(0x99),
            .data(0x43),
            .command(TelnetCommand.se)
        ])
    }
}

@Suite("TelnetProcessor — lifecycle")
struct TelnetProcessorLifecycleTests {
    @Test("reset() clears in-progress state")
    func resetClearsInProgressState() {
        var processor = TelnetProcessor()
        var events: [TelnetEvent] = []
        processor.process([
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp, 0x41
        ]) { events.append($0) }
        #expect(events.isEmpty)

        processor.reset()
        processor.process([0x42]) { events.append($0) }
        #expect(events == [.data(0x42)])
    }
}

@Suite("TelnetProcessor — realistic snippets")
struct TelnetProcessorRealisticTests {
    @Test("Handshake snippet: IAC WILL GMCP, data, IAC SB GMCP … IAC SE")
    func realisticHandshakeSnippet() {
        var bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.will, TelnetOption.gmcp,
            0x48, 0x69, 0x0A
        ]
        bytes.append(contentsOf: [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp
        ])
        bytes.append(contentsOf: Array("X".utf8))
        bytes.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])

        let events = TelnetProcessorHarness.collect(bytes)
        #expect(events == [
            .negotiate(verb: .will, option: TelnetOption.gmcp),
            .data(0x48), .data(0x69), .data(0x0A),
            .subnegotiation(option: TelnetOption.gmcp, payload: [0x58])
        ])
    }
}

// MARK: - Harness

enum TelnetProcessorHarness {
    static func collect(_ bytes: [UInt8]) -> [TelnetEvent] {
        var processor = TelnetProcessor()
        var events: [TelnetEvent] = []
        processor.process(bytes) { events.append($0) }
        return events
    }
}
