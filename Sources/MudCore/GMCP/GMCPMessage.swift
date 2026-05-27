import Foundation

/// One decoded GMCP message: a dotted package name and its JSON payload
/// (PLAN.md §5.5).
///
/// GMCP rides on telnet option 201 as `IAC SB 201 <payload> IAC SE`, where
/// the payload is `"Package.SubName <space> <JSON>"` — e.g.
/// `Char.Vitals {"hp":1234,"mana":900,"moves":500}`. The bracketing telnet
/// bytes and any `IAC IAC` escaping are already removed by
/// ``TelnetProcessor`` before we see the payload here.
///
/// Package names are case-sensitive on the wire (Aardwolf sends
/// `Char.Vitals`, `Room.Info`, …) and the JSON is usually an object or
/// array but may be absent (e.g. `Core.Ping`). When absent, ``json`` is
/// `"{}"` so callers can always attempt a decode.
public struct GMCPMessage: Sendable, Equatable {
    /// Dotted package name, e.g. `"Char.Vitals"`. Trimmed of surrounding
    /// whitespace; original casing preserved.
    public let package: String

    /// Raw JSON text following the package name, trimmed. `"{}"` when the
    /// message carried no data.
    public let json: String

    public init(package: String, json: String) {
        self.package = package
        self.json = json.isEmpty ? "{}" : json
    }

    /// Parse a GMCP message from a subnegotiation payload (option 201).
    /// Splits on the first run of ASCII whitespace: everything before is
    /// the package name, everything after (trimmed) is the JSON. Returns
    /// `nil` if the bytes aren't valid UTF-8 or the package name is empty.
    public init?(subnegotiationPayload payload: [UInt8]) {
        guard let text = String(bytes: payload, encoding: .utf8) else {
            return nil
        }
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard let split = text.firstIndex(where: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        }) else {
            // No whitespace: the whole payload is the package name.
            let name = text.trimmingCharacters(in: whitespace)
            guard !name.isEmpty else { return nil }
            self.init(package: name, json: "")
            return
        }
        let name = String(text[..<split]).trimmingCharacters(in: whitespace)
        guard !name.isEmpty else { return nil }
        let body = String(text[text.index(after: split)...])
            .trimmingCharacters(in: whitespace)
        self.init(package: name, json: body)
    }

    /// Decode the JSON payload into `T`. Throws on malformed JSON or a
    /// shape mismatch.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

public extension GMCPMessage {
    /// Frame a GMCP payload string as a telnet subnegotiation:
    /// `IAC SB 201 <payload> IAC SE`, doubling any `IAC` (0xFF) byte
    /// inside the payload (the inverse of what ``TelnetProcessor`` undoes
    /// on receive).
    static func encode(payload: String) -> [UInt8] {
        var bytes: [UInt8] = [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.gmcp]
        for byte in payload.utf8 {
            bytes.append(byte)
            if byte == TelnetCommand.iac {
                bytes.append(TelnetCommand.iac)
            }
        }
        bytes.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])
        return bytes
    }

    /// The client→server GMCP handshake Proteles sends once the server
    /// enables GMCP, mirroring `aard_GMCP_handler.xml`'s `fetch_all()`:
    /// announce ourselves, declare supported modules, then request the
    /// current character / room / area state and set a few display
    /// configs. Each element is a fully framed subnegotiation.
    static func aardwolfHandshake(clientVersion: String) -> [[UInt8]] {
        let payloads = [
            #"Core.Hello { "client": "Proteles", "version": "\#(clientVersion)" }"#,
            #"Core.Supports.Set [ "Char 1", "Comm 1", "Room 1" ]"#,
            "config compact",
            "config prompt",
            "config xterm yes",
            "rawcolor on",
            "request char",
            "request room",
            "request area",
            // The sector palette (terrain → colour index); without it the
            // mapper can't colour rooms (it falls back to the persisted
            // environments table — see Mapper.seedTerrainPaletteFromStore).
            "request sectors",
            "request quest",
            "request group"
        ]
        return payloads.map { encode(payload: $0) }
    }
}
