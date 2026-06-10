import Foundation
@testable import MudCore
import Testing

@Suite("Keypad — key codes")
struct KeypadKeyCodeTests {
    @Test("every key round-trips through its macOS key code")
    func roundTrip() {
        for key in KeypadKey.allCases {
            #expect(KeypadKey(keyCode: key.keyCode) == key)
        }
    }

    @Test("the 17 bindable keys have 17 distinct key codes")
    func distinctCodes() {
        let codes = Set(KeypadKey.allCases.map(\.keyCode))
        #expect(codes.count == KeypadKey.allCases.count)
        #expect(KeypadKey.allCases.count == 17)
    }

    @Test("non-keypad codes and keypad Enter map to nil")
    func unknownCodes() {
        #expect(KeypadKey(keyCode: 0) == nil) // the letter A
        #expect(KeypadKey(keyCode: KeyCode.keypadEnter) == nil)
    }
}

@Suite("Keypad — runtime match (D-102)")
struct KeypadMatchTests {
    private let keypad = Keypad(enabled: true, bindings: [
        KeypadBinding(key: .num8, command: "north")
    ])

    @Test("a bound bare keypad key fires its command")
    func fires() {
        let chord = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        #expect(keypad.action(for: chord) == .command("north"))
    }

    @Test("the master toggle gates everything")
    func disabled() {
        var off = keypad
        off.enabled = false
        let chord = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        #expect(off.action(for: chord) == nil)
    }

    @Test("modifier combos never match — they stay free for macros")
    func modifiers() {
        let chord = KeyChord(
            keyCode: KeyCode.keypad8, modifiers: [.command], isKeypad: true
        )
        #expect(keypad.action(for: chord) == nil)
    }

    @Test("an unbound key and a non-keypad chord match nothing")
    func misses() {
        #expect(keypad.action(for: KeyChord(keyCode: KeyCode.keypad5, isKeypad: true)) == nil)
        // The main-row 8 reports the same semantics but isKeypad false.
        #expect(keypad.action(for: KeyChord(keyCode: 28)) == nil)
    }

    @Test("the default layout matches the D-50 navigation set")
    func defaults() {
        let layout = Keypad.defaultNavigation
        #expect(layout.enabled)
        #expect(layout.bindings.count == 11)
        #expect(layout.command(for: .num8) == "north")
        #expect(layout.command(for: .num5) == "look")
        #expect(layout.command(for: .divide) == "inv")
        #expect(layout.command(for: .clear) == nil)
    }
}

@Suite("Keypad — D-50 macro migration (D-102)")
struct KeypadMigrationTests {
    private let defaults = MacroEngine.defaultNavigationMacros()

    @Test("with an empty keypad, untouched default macros MOVE into bindings")
    func movesDefaults() throws {
        let custom = Macro(
            name: "mine",
            chord: KeyChord(keyCode: KeyCode.f5, isFunctionKey: true),
            action: .command("cast sanc")
        )
        let result = try #require(KeypadMigration.migrate(
            macros: defaults + [custom], keypad: Keypad()
        ))
        #expect(result.macros == [custom])
        #expect(result.keypad.bindings.count == defaults.count)
        #expect(result.keypad.command(for: .num8) == "north")
        #expect(result.keypad.command(for: .multiply) == "eq")
    }

    @Test("with an imported keypad, untouched defaults are REMOVED, not moved")
    func removesShadowingDefaults() throws {
        let imported = Keypad(enabled: true, bindings: [
            KeypadBinding(key: .num8, command: "sweep kill"),
            KeypadBinding(key: .num7, command: "xcp 1")
        ])
        let result = try #require(KeypadMigration.migrate(
            macros: defaults, keypad: imported
        ))
        #expect(result.macros.isEmpty)
        #expect(result.keypad == imported)
    }

    @Test("a customised default (re-bound, renamed, or disabled) stays a macro")
    func keepsCustomised() throws {
        var rebound = defaults[0] // North on keypad-8
        rebound.action = .command("run n")
        var disabled = defaults[1] // South on keypad-2
        disabled.enabled = false
        let untouched = Array(defaults.dropFirst(2))
        let result = try #require(KeypadMigration.migrate(
            macros: [rebound, disabled] + untouched, keypad: Keypad()
        ))
        #expect(result.macros == [rebound, disabled])
        #expect(result.keypad.command(for: .num8) == nil)
        #expect(result.keypad.command(for: .num4) == "west")
    }

    @Test("migration is idempotent — a second run has nothing to do")
    func idempotent() throws {
        let first = try #require(KeypadMigration.migrate(
            macros: defaults, keypad: Keypad()
        ))
        #expect(KeypadMigration.migrate(
            macros: first.macros, keypad: first.keypad
        ) == nil)
    }

    @Test("no defaults present → nil (a fresh or fully-customised set)")
    func nothingToDo() {
        let custom = Macro(
            name: "mine",
            chord: KeyChord(keyCode: KeyCode.keypad8, isKeypad: true),
            action: .command("hunt next")
        )
        #expect(KeypadMigration.migrate(macros: [custom], keypad: Keypad()) == nil)
        #expect(KeypadMigration.migrate(macros: [], keypad: Keypad()) == nil)
    }
}
