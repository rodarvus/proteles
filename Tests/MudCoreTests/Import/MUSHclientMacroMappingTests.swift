@testable import MudCore
import Testing

@Suite("MUSHclient macros → Proteles macros")
struct MUSHclientMacroMappingTests {
    @Test("Alt+letter and F-keys (any modifier order) map to key chords")
    func keyedSlots() throws {
        #expect(MUSHclientMacroMapping.keyChord(forSlot: "Alt+A")
            == KeyChord(keyCode: 0, modifiers: [.option])) // 'a' == keyCode 0
        let f2 = try #require(MUSHclientMacroMapping.keyChord(forSlot: "F2"))
        #expect(f2.isFunctionKey && f2.modifiers.isEmpty)
        // MUSHclient writes the modifier AFTER the key here — still parses.
        let f10c = try #require(MUSHclientMacroMapping.keyChord(forSlot: "F10+Ctrl"))
        #expect(f10c.isFunctionKey && f10c.modifiers.contains(.control))
    }

    @Test("named game-command slots are unbound — even ones that look like keys")
    func namedSlotsUnbound() {
        for name in ["down", "north", "examine", "logout", "quit", "up", "left"] {
            #expect(MUSHclientMacroMapping.keyChord(forSlot: name) == nil, "\(name) should be unbound")
        }
    }

    @Test("macros(from:): keyed → chord, named → unbound sentinel, empty send dropped")
    func mapsMacros() {
        let slots: [MUSHclientWorldFile.Macro] = [
            .init(name: "Alt+A", send: "kill rat", type: "send_now"),
            .init(name: "down", send: "down", type: "send_now"),
            .init(name: "F5", send: "", type: "send_now") // empty → dropped
        ]
        let macros = MUSHclientMacroMapping.macros(from: slots)
        #expect(macros.count == 2)
        let alt = macros.first { $0.name == "Alt+A" }
        #expect(alt?.chord.keyCode == 0 && alt?.chord.modifiers == [.option])
        #expect(alt?.action == .command("kill rat"))
        // "down" imported unbound (keyCode 0, no modifiers) — the editor shows "Record Key".
        let down = macros.first { $0.name == "down" }
        #expect(down?.chord == KeyChord(keyCode: 0))
        #expect(down?.action == .command("down"))
    }
}
