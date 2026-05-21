import Foundation
@testable import MudCore
import Testing

@Suite("GMCPMessage — parsing")
struct GMCPMessageParsingTests {
    private func parse(_ text: String) -> GMCPMessage? {
        GMCPMessage(subnegotiationPayload: Array(text.utf8))
    }

    @Test("Splits package name from JSON on the first space")
    func splitsOnFirstSpace() {
        let message = parse(#"Char.Vitals {"hp":1234,"mana":900,"moves":500}"#)
        #expect(message?.package == "Char.Vitals")
        #expect(message?.json == #"{"hp":1234,"mana":900,"moves":500}"#)
    }

    @Test("Preserves case-sensitive package names")
    func preservesCase() {
        #expect(parse(#"Room.Info {"num":12345}"#)?.package == "Room.Info")
        #expect(parse(#"Char.MaxStats {"maxhp":2000}"#)?.package == "Char.MaxStats")
    }

    @Test("A package with no payload yields {} JSON")
    func noPayload() {
        let message = parse("Core.Ping")
        #expect(message?.package == "Core.Ping")
        #expect(message?.json == "{}")
    }

    @Test("Trailing whitespace after the package name yields {} JSON")
    func trailingWhitespaceOnly() {
        let message = parse("Core.Ping   ")
        #expect(message?.package == "Core.Ping")
        #expect(message?.json == "{}")
    }

    @Test("JSON containing spaces is preserved after the first split")
    func jsonWithSpaces() {
        let message = parse(#"Comm.Channel {"chan": "tell", "msg": "hi there", "player": "Bob"}"#)
        #expect(message?.package == "Comm.Channel")
        #expect(message?.json == #"{"chan": "tell", "msg": "hi there", "player": "Bob"}"#)
    }

    @Test("Array payloads are preserved")
    func arrayPayload() {
        let message = parse(#"Char.Status.Vars ["a","b"]"#)
        #expect(message?.json == #"["a","b"]"#)
    }

    @Test("Empty payload returns nil")
    func emptyPayload() {
        #expect(GMCPMessage(subnegotiationPayload: []) == nil)
    }

    @Test("Invalid UTF-8 returns nil")
    func invalidUTF8() {
        #expect(GMCPMessage(subnegotiationPayload: [0xFF, 0xFE, 0xFD]) == nil)
    }
}

@Suite("GMCPMessage — decoding")
struct GMCPMessageDecodingTests {
    private struct Vitals: Decodable, Equatable {
        let hp: Int
        let mana: Int
        let moves: Int
    }

    @Test("Decodes the JSON payload into a Codable type")
    func decodesPayload() throws {
        let message = GMCPMessage(package: "Char.Vitals", json: #"{"hp":10,"mana":20,"moves":30}"#)
        let vitals = try message.decode(Vitals.self)
        #expect(vitals == Vitals(hp: 10, mana: 20, moves: 30))
    }

    @Test("Throws on malformed JSON")
    func throwsOnGarbage() {
        let message = GMCPMessage(package: "Char.Vitals", json: "not json")
        #expect(throws: (any Error).self) {
            _ = try message.decode(Vitals.self)
        }
    }
}
