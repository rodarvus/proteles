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

    @Test("macros(from:): keyed → chord; identity + empty dropped; customized named → unbound")
    func mapsMacros() {
        let slots: [MUSHclientWorldFile.Macro] = [
            .init(name: "Alt+A", send: "kill rat", type: "send_now"),
            .init(name: "north", send: "north", type: "send_now"), // identity → dropped
            .init(name: "examine", send: "look in corpse", type: "send_now"), // customized → kept
            .init(name: "F5", send: "", type: "send_now") // empty → dropped
        ]
        let macros = MUSHclientMacroMapping.macros(from: slots)
        #expect(macros.count == 2)
        let alt = macros.first { $0.name == "Alt+A" }
        #expect(alt?.chord.keyCode == 0 && alt?.chord.modifiers == [.option])
        #expect(alt?.action == .command("kill rat"))
        #expect(!macros.contains { $0.name == "north" }) // identity slot dropped
        // a named slot with a *custom* command is kept, unbound (editor shows "Record Key").
        let examine = macros.first { $0.name == "examine" }
        #expect(examine?.chord == KeyChord(keyCode: 0))
        #expect(examine?.action == .command("look in corpse"))
    }
}

@Suite("MUSHclient replace-type macros → .replaceInput")
struct MUSHclientReplaceMacroTests {
    @Test("identity named slots are dropped whatever their type — antique Game-menu defaults")
    func identityDefaultsDropped() {
        let slots: [MUSHclientWorldFile.Macro] = [
            .init(name: "say", send: "say ", type: "replace"), // default prefill → dropped
            .init(name: "drop", send: "drop", type: "replace"), // identity replace → dropped
            .init(name: "examine", send: "examine", type: "replace"), // identity replace → dropped
            .init(name: "north", send: "north", type: "send_now") // identity send-now → dropped
        ]
        #expect(MUSHclientMacroMapping.macros(from: slots).isEmpty)
    }

    @Test("type=replace → .replaceInput (trailing space kept); keyed slots are never identity-dropped")
    func replaceType() {
        let slots: [MUSHclientWorldFile.Macro] = [
            .init(name: "F3", send: "say ", type: "replace"), // keyed prefill → kept
            .init(name: "whisper", send: "tell a friend ", type: "replace"), // customized named → kept
            .init(name: "F2", send: "kill rat", type: "send_now") // keyed send → command
        ]
        let macros = MUSHclientMacroMapping.macros(from: slots)
        #expect(macros.count == 3)
        #expect(macros.first { $0.name == "F3" }?.action == .replaceInput("say ")) // trailing space kept
        #expect(macros.first { $0.name == "whisper" }?.action == .replaceInput("tell a friend "))
        #expect(macros.first { $0.name == "F2" }?.action == .command("kill rat"))
    }
}
