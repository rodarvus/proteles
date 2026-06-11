import Foundation

/// Pure translation between Proteles' telnet byte stream and Aardwolf's
/// WebSocket-gateway framing (`wss://play.aardwolf.com:6200/`), separated from
/// the socket I/O so it's unit-testable.
///
/// Confirmed by probing the live gateway + reading its reference web client:
///   - **Inbound** each WS text frame is `base64( an *independent* raw-DEFLATE
///     stream )` wrapping a slice of the telnet stream — the gateway compresses
///     per frame with no shared context (unlike MCCP2's one continuous stream),
///     so the inflater is **reset before every frame**.
///   - **Outbound** the gateway wants *text* frames, never binary: a plain
///     command line as text, and GMCP as a `{"gmcp": "<payload>"}` JSON message.
///     It negotiates telnet with the MUD itself (driven by the JSON handshake),
///     so the client's own telnet negotiation bytes are dropped.
public enum WebSocketFraming {
    /// A frame to put on the wire (always a WebSocket *text* message).
    public enum Outbound: Equatable, Sendable {
        case text(String) // a command line (sent verbatim)
        case gmcp(String) // a GMCP payload, wrapped as {"gmcp": "..."}
    }

    private static let iac: UInt8 = 255
    private static let sb: UInt8 = 250
    private static let se: UInt8 = 240
    private static let gmcpOption: UInt8 = 201

    /// Translate a chunk of outbound telnet bytes into gateway frames:
    /// plaintext (commands) → ``Outbound/text``; `IAC SB GMCP … IAC SE` →
    /// ``Outbound/gmcp``; every other IAC sequence (negotiation, other
    /// subnegotiations like Aardwolf-102, NOP) is **dropped** — the gateway
    /// handles telnet negotiation on the client's behalf.
    public static func outboundFrames(from bytes: [UInt8]) -> [Outbound] {
        var frames: [Outbound] = []
        var text: [UInt8] = []
        func flushText() {
            guard !text.isEmpty else { return }
            if let string = String(bytes: text, encoding: .utf8) {
                frames.append(.text(string))
            }
            text.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            guard byte == iac else { text.append(byte); i += 1; continue }
            guard i + 1 < bytes.count else { break } // dangling IAC
            let command = bytes[i + 1]
            switch command {
            case sb:
                let sub = readSubnegotiation(bytes, from: i)
                if sub.option == gmcpOption, let string = String(bytes: sub.payload, encoding: .utf8) {
                    flushText()
                    frames.append(.gmcp(string))
                } // other subnegotiations are dropped
                i = sub.next
            case iac: // escaped 0xFF → a literal data byte
                text.append(iac)
                i += 2
            case 251, 252, 253, 254: // WILL / WONT / DO / DONT — 3 bytes, dropped
                i += 3
            default: // NOP, GA, … — 2 bytes, dropped
                i += 2
            }
        }
        flushText()
        return frames
    }

    /// A parsed `IAC SB <option> <payload> IAC SE`.
    private struct Subnegotiation {
        var payload: [UInt8]
        var option: UInt8
        /// Index just past the closing `IAC SE` (or end-of-buffer if unterminated).
        var next: Int
    }

    /// Read the subnegotiation starting at `start` (which points at the `IAC`).
    private static func readSubnegotiation(_ bytes: [UInt8], from start: Int) -> Subnegotiation {
        guard start + 2 < bytes.count
        else { return Subnegotiation(payload: [], option: 0, next: bytes.count) }
        let option = bytes[start + 2]
        var j = start + 3
        while j + 1 < bytes.count, !(bytes[j] == iac && bytes[j + 1] == se) {
            j += 1
        }
        if j + 1 < bytes.count { // found IAC SE
            return Subnegotiation(payload: Array(bytes[(start + 3)..<j]), option: option, next: j + 2)
        }
        return Subnegotiation(payload: Array(bytes[(start + 3)...]), option: option, next: bytes.count)
    }

    /// `{"gmcp": "<payload>"}` with the payload correctly JSON-escaped.
    public static func gmcpJSON(_ payload: String) -> String {
        let encoded = (try? JSONEncoder().encode(payload)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "\"\""
        return "{\"gmcp\":\(encoded)}"
    }

    /// The JSON handshake sent once on connect: tells the gateway which MUD to
    /// bridge to + which protocols to enable. `mccp:0` — the WS frames are already
    /// deflated, so telnet-level MCCP would double-compress.
    public static func handshakeJSON(
        host: String, port: UInt16, ttype: String, client: String
    ) -> String {
        let fields: [(String, String)] = [
            ("host", "\"\(host)\""), ("port", "\(port)"),
            ("connect", "1"), ("gmcp", "1"), ("mccp", "0"), ("utf8", "1"), ("mxp", "0"),
            ("ttype", "\"\(ttype)\""), ("client", "\"\(client)\"")
        ]
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    /// An inbound frame that can't be decoded — the telnet stream now has a
    /// hole of unknown content (it may end mid-line or mid-IAC), so callers
    /// must treat this as a connection-level failure, not skip the frame
    /// (#46 audit A4: the old `try?` degraded corruption to silent loss).
    public enum FrameError: Error, Equatable {
        case notBase64
        case corruptDeflate(String)
    }

    /// Decode one inbound WS text frame: base64 → raw-deflate → telnet bytes.
    /// Each frame is its **own** complete deflate stream, so the inflater is reset
    /// first (carrying state across frames leaves the second frame undecodable —
    /// which silently swallowed the `Password:` prompt and broke login). Throws
    /// ``FrameError`` on a non-base64 or corrupt-deflate frame.
    public static func inboundBytes(fromBase64 frame: String, inflater: Inflater) throws -> [UInt8] {
        let trimmed = frame.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { throw FrameError.notBase64 }
        do {
            try inflater.reset()
            return try inflater.inflate([UInt8](data))
        } catch {
            throw FrameError.corruptDeflate(String(describing: error))
        }
    }
}
