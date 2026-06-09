import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclient keypad → Proteles Keypad")
struct MUSHclientKeypadMappingTests {
    @Test("maps numpad labels to keys; drops unknown labels + empty commands")
    func maps() {
        let keys: [MUSHclientWorldFile.KeypadKey] = [
            .init(key: "8", send: "north"),
            .init(key: "2", send: "south"),
            .init(key: "/", send: "cast 'spear of odin'"),
            .init(key: "5", send: ""), // empty → dropped
            .init(key: "?", send: "nope") // unknown label → dropped
        ]
        let keypad = MUSHclientKeypadMapping.keypad(from: keys)
        #expect(keypad.bindings.count == 3)
        #expect(keypad.command(for: .num8) == "north")
        #expect(keypad.command(for: .num2) == "south")
        #expect(keypad.command(for: .divide) == "cast 'spear of odin'")
        #expect(keypad.command(for: .num5) == nil)
    }

    @Test("Keypad round-trips through Codable")
    func codable() throws {
        let keypad = Keypad(enabled: true, bindings: [.init(key: .add, command: "down")])
        let data = try JSONEncoder().encode(keypad)
        #expect(try JSONDecoder().decode(Keypad.self, from: data) == keypad)
    }
}
