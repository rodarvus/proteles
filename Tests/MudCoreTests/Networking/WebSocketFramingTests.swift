import Foundation
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
        let out = try WebSocketFraming.inboundBytes(
            fromBase64: "C0/NSc7PTVUoyVdwTCxKKc/PSQMA",
            inflater: inflater
        )
        #expect(String(bytes: out, encoding: .utf8) == "Welcome to Aardwolf")
    }

    // MARK: - Corrupt frames are loud, not silent (#46 audit A4)

    @Test("a non-base64 frame throws (was: silently dropped)")
    func nonBase64FrameThrows() throws {
        let inflater = try Inflater(raw: true)
        #expect(throws: WebSocketFraming.FrameError.notBase64) {
            try WebSocketFraming.inboundBytes(fromBase64: "not!!base64@@", inflater: inflater)
        }
    }

    @Test("a corrupt deflate stream throws (was: silent garbage/loss)")
    func corruptDeflateThrows() throws {
        let inflater = try Inflater(raw: true)
        // Valid base64 of bytes that are NOT a raw-deflate stream.
        let corrupt = Data([0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x01, 0x02]).base64EncodedString()
        #expect {
            try WebSocketFraming.inboundBytes(fromBase64: corrupt, inflater: inflater)
        } throws: { error in
            if case WebSocketFraming.FrameError.corruptDeflate = error { return true }
            return false
        }
    }

    @Test("a corrupt frame doesn't poison the next frame's decode")
    func inflaterRecoversAfterCorruptFrame() throws {
        let inflater = try Inflater(raw: true)
        let corrupt = Data([0xFF, 0xFE, 0xFD, 0xFC]).base64EncodedString()
        _ = try? WebSocketFraming.inboundBytes(fromBase64: corrupt, inflater: inflater)
        // The per-frame reset means a subsequent good frame still decodes —
        // the connection layer chooses to disconnect anyway (the corrupt
        // frame's CONTENT is lost), but the framing layer itself recovers.
        let out = try WebSocketFraming.inboundBytes(
            fromBase64: "C0/NSc7PTVUoyVdwTCxKKc/PSQMA",
            inflater: inflater
        )
        #expect(String(bytes: out, encoding: .utf8) == "Welcome to Aardwolf")
    }
}
