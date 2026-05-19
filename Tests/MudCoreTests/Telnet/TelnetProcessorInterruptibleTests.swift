@testable import MudCore
import Testing

@Suite("TelnetProcessor — interruptible processing")
struct TelnetProcessorInterruptibleTests {
    @Test("Processing the full input returns count = bytes.count")
    func consumesEverythingWhenNotInterrupted() {
        var processor = TelnetProcessor()
        let bytes: [UInt8] = [0x41, 0x42, 0x43]
        let consumed = processor.processInterruptible(bytes) { _ in true }
        #expect(consumed == 3)
    }

    @Test("Returning false from emit stops after the current event")
    func haltsAfterMatchingEvent() {
        var processor = TelnetProcessor()
        // SB GMCP <empty payload> SE | <unrelated trailing bytes>
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp,
            TelnetCommand.iac, TelnetCommand.se,
            0x41, 0x42, 0x43
        ]
        var events: [TelnetEvent] = []
        let consumed = processor.processInterruptible(bytes) { event in
            events.append(event)
            if case .subnegotiation(option: TelnetOption.gmcp, _) = event {
                return false
            }
            return true
        }

        #expect(events == [
            .subnegotiation(option: TelnetOption.gmcp, payload: [])
        ])
        // The SB...SE sequence is 5 bytes; processing halts after.
        #expect(consumed == 5)
    }

    @Test("Caller can resume processing from the unconsumed tail")
    func canResumeAfterHalt() {
        var processor = TelnetProcessor()
        // Plain bytes around an MCCP2-style subneg marker; here we
        // simulate "stop after the subneg, then process trailing
        // plain bytes via a second call".
        let bytes: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.mccp2,
            TelnetCommand.iac, TelnetCommand.se,
            0x44, 0x45, 0x46
        ]
        var events: [TelnetEvent] = []
        let consumed = processor.processInterruptible(bytes) { event in
            events.append(event)
            if case .subnegotiation(option: TelnetOption.mccp2, _) = event {
                return false
            }
            return true
        }
        #expect(consumed == 5)

        // Resume with the remainder; nothing special should happen
        // (these would be compressed bytes in the real MCCP2 path, but
        // here they're just plain text data events).
        let remainder = Array(bytes[consumed...])
        processor.process(remainder) { events.append($0) }
        #expect(events == [
            .subnegotiation(option: TelnetOption.mccp2, payload: []),
            .data(0x44), .data(0x45), .data(0x46)
        ])
    }

    @Test("Empty input consumes zero bytes")
    func emptyInputConsumesZero() {
        var processor = TelnetProcessor()
        let consumed = processor.processInterruptible([]) { _ in true }
        #expect(consumed == 0)
    }
}
