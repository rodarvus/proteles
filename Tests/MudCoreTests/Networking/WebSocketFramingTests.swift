@testable import MudCore
import Testing

@Suite("WebSocketFraming — Aardwolf gateway protocol (#ws)")
struct WebSocketFramingTests {
    private static let iac: UInt8 = 255, sb: UInt8 = 250, se: UInt8 = 240, gmcp: UInt8 = 201

    @Test("a plain command becomes a text frame")
    func commandText() {
        let bytes = Array("look\r\n".utf8)
        #expect(WebSocketFraming.outboundFrames(from: bytes) == [.text("look\r\n")])
    }

    @Test("IAC SB GMCP … IAC SE becomes a gmcp frame")
    func gmcpFrame() {
        let payload = "Core.Hello { \"client\": \"Proteles\" }"
        var bytes: [UInt8] = [Self.iac, Self.sb, Self.gmcp]
        bytes += Array(payload.utf8)
        bytes += [Self.iac, Self.se]
        #expect(WebSocketFraming.outboundFrames(from: bytes) == [.gmcp(payload)])
    }

    @Test("telnet negotiation + non-GMCP subnegotiations are dropped")
    func negotiationDropped() {
        // IAC DO GMCP (3 bytes) + IAC SB 102 <x> IAC SE (Aardwolf tags) → nothing.
        let bytes: [UInt8] = [
            Self.iac,
            253,
            Self.gmcp,
            Self.iac,
            Self.sb,
            102,
            1,
            1,
            Self.iac,
            Self.se
        ]
        #expect(WebSocketFraming.outboundFrames(from: bytes).isEmpty)
    }

    @Test("mixed command + GMCP splits into two frames in order")
    func mixed() {
        var bytes = Array("kill rat\r\n".utf8)
        bytes += [Self.iac, Self.sb, Self.gmcp] + Array("Char.Items".utf8) + [Self.iac, Self.se]
        #expect(WebSocketFraming.outboundFrames(from: bytes) == [.text("kill rat\r\n"), .gmcp("Char.Items")])
    }

    @Test("gmcpJSON escapes the payload")
    func gmcpJSONEscaping() {
        let json = WebSocketFraming.gmcpJSON("Core.Hello { \"x\": 1 }")
        #expect(json == #"{"gmcp":"Core.Hello { \"x\": 1 }"}"#)
    }

    @Test("inbound frame: base64 → raw-deflate → telnet bytes")
    func inboundRoundTrip() throws {
        let inflater = try Inflater(raw: true)
        let out = WebSocketFraming.inboundBytes(
            fromBase64: "C0/NSc7PTVUoyVdwTCxKKc/PSQMA",
            inflater: inflater
        )
        #expect(String(bytes: out, encoding: .utf8) == "Welcome to Aardwolf")
    }
}
