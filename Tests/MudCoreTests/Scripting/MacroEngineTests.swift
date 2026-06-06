import Foundation
@testable import MudCore
import Testing

@Suite("MacroEngine — matching + tiers")
struct MacroEngineTests {
    // MARK: - Tier classification

    @Test("A ⌘/⌥/⌃ modifier puts a key in the always-fire chord tier")
    func modifierIsChordTier() {
        for modifier in [KeyModifiers.command, .option, .control] {
            let chord = KeyChord(keyCode: 0, modifiers: modifier)
            #expect(MacroEngine.tier(for: chord) == .chord)
        }
    }

    @Test("Shift alone does not promote a bare key (it is just uppercase typing)")
    func shiftAloneStaysBare() {
        let chord = KeyChord(keyCode: 1, modifiers: .shift)
        #expect(MacroEngine.tier(for: chord) == .bare)
    }

    @Test("Function keys are always-fire chords")
    func functionKeyIsChordTier() {
        let chord = KeyChord(keyCode: 122, isFunctionKey: true)
        #expect(MacroEngine.tier(for: chord) == .chord)
    }

    @Test("A keypad key is the keypad tier")
    func keypadTier() {
        let chord = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        #expect(MacroEngine.tier(for: chord) == .keypad)
    }

    @Test("A bare main-keyboard key is the bare tier")
    func bareTier() {
        let chord = KeyChord(keyCode: 45) // 'n', no modifiers/flags
        #expect(MacroEngine.tier(for: chord) == .bare)
    }

    // MARK: - Matching

    @Test("A modifier chord fires regardless of input/navigation state")
    func chordFiresAlways() {
        let chord = KeyChord(keyCode: 38, modifiers: .command) // ⌘J
        let engine = MacroEngine([Macro(chord: chord, action: .command("juke"))])
        let contexts = [
            MacroContext(inputIsEmpty: false, navigationModeOn: false),
            MacroContext(inputIsEmpty: true, navigationModeOn: true)
        ]
        for context in contexts {
            #expect(engine.match(chord, context: context)?.action == .command("juke"))
        }
    }

    @Test("A keypad key fires even while typing")
    func keypadFiresWhileTyping() {
        let chord = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        let engine = MacroEngine([Macro(chord: chord, action: .command("n"))])
        let context = MacroContext(inputIsEmpty: false, navigationModeOn: false)
        #expect(engine.match(chord, context: context)?.action == .command("n"))
    }

    @Test("A bare key fires only with Navigation mode on AND an empty input")
    func bareKeyGating() {
        let chord = KeyChord(keyCode: 45) // bare 'n'
        let engine = MacroEngine([Macro(chord: chord, action: .command("n"))])

        #expect(engine.match(chord, context: MacroContext(inputIsEmpty: true, navigationModeOn: true)) != nil)
        #expect(engine
            .match(chord, context: MacroContext(inputIsEmpty: false, navigationModeOn: true)) == nil)
        #expect(engine
            .match(chord, context: MacroContext(inputIsEmpty: true, navigationModeOn: false)) == nil)
        #expect(engine
            .match(chord, context: MacroContext(inputIsEmpty: false, navigationModeOn: false)) == nil)
    }

    @Test("An unbound chord matches nothing")
    func unboundChord() {
        let engine = MacroEngine([Macro(
            chord: KeyChord(keyCode: 1, modifiers: .command),
            action: .command("x")
        )])
        let other = KeyChord(keyCode: 2, modifiers: .command)
        #expect(engine.match(other, context: MacroContext()) == nil)
    }

    @Test("A disabled macro never fires")
    func disabledMacro() {
        let chord = KeyChord(keyCode: 1, modifiers: .command)
        let engine = MacroEngine([Macro(chord: chord, action: .command("x"), enabled: false)])
        #expect(engine.match(chord, context: MacroContext()) == nil)
    }

    @Test("Equality distinguishes keypad and main-row keys with the same code")
    func keypadFlagAffectsIdentity() {
        let keypad = KeyChord(keyCode: 84, isKeypad: true)
        let mainRow = KeyChord(keyCode: 84, isKeypad: false)
        #expect(keypad != mainRow)
        let engine = MacroEngine([Macro(chord: keypad, action: .command("s"))])
        #expect(engine.match(mainRow, context: MacroContext()) == nil)
    }

    // MARK: - Mutation

    @Test("add / remove / setEnabled mutate the set")
    func mutation() {
        var engine = MacroEngine()
        let macro = Macro(chord: KeyChord(keyCode: 1, modifiers: .command), action: .command("x"))
        engine.add(macro)
        #expect(engine.allMacros.count == 1)

        engine.setEnabled(false, id: macro.id)
        #expect(engine.allMacros.first?.enabled == false)

        engine.remove(id: macro.id)
        #expect(engine.allMacros.isEmpty)
    }

    @Test("replaceAll swaps the whole set")
    func replaceAll() {
        var engine = MacroEngine([Macro(chord: KeyChord(keyCode: 1), action: .command("a"))])
        engine.replaceAll(MacroEngine.defaultNavigationMacros())
        #expect(engine.allMacros.count == 11)
    }

    // MARK: - Defaults

    @Test("Default keypad set mirrors the Aardwolf.mcl layout (no diagonals)")
    func defaultsLayout() {
        let macros = MacroEngine.defaultNavigationMacros()
        // Every default is a keypad chord with no modifiers (fires while typing).
        #expect(macros.allSatisfy { $0.chord.isKeypad && $0.chord.modifiers.isEmpty })

        func command(forKeyCode keyCode: UInt16) -> String? {
            guard let macro = macros.first(where: { $0.chord.keyCode == keyCode }) else { return nil }
            if case .command(let text) = macro.action { return text }
            return nil
        }
        #expect(command(forKeyCode: KeyCode.keypad8) == "north")
        #expect(command(forKeyCode: KeyCode.keypad2) == "south")
        #expect(command(forKeyCode: KeyCode.keypad4) == "west")
        #expect(command(forKeyCode: KeyCode.keypad6) == "east")
        #expect(command(forKeyCode: KeyCode.keypad5) == "look")
        #expect(command(forKeyCode: KeyCode.keypad0) == "scan")
        #expect(command(forKeyCode: KeyCode.keypadMinus) == "up")
        #expect(command(forKeyCode: KeyCode.keypadPlus) == "down")
        #expect(command(forKeyCode: KeyCode.keypadDecimal) == "score")
        #expect(command(forKeyCode: KeyCode.keypadDivide) == "inv")
        #expect(command(forKeyCode: KeyCode.keypadMultiply) == "eq")

        // Diagonals are intentionally unbound (Aardwolf has no ne/nw/se/sw).
        for diagonal in [KeyCode.keypad1, KeyCode.keypad3, KeyCode.keypad7, KeyCode.keypad9] {
            #expect(command(forKeyCode: diagonal) == nil)
        }
    }

    @Test("A default keypad macro fires through the engine while typing")
    func defaultsFireWhileTyping() {
        let engine = MacroEngine(MacroEngine.defaultNavigationMacros())
        let north = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        let context = MacroContext(inputIsEmpty: false, navigationModeOn: false)
        #expect(engine.match(north, context: context)?.action == .command("north"))
    }

    @Test("Every keypad default carries a key code in the keypad set")
    func defaultsUseKnownKeypadCodes() {
        for macro in MacroEngine.defaultNavigationMacros() {
            #expect(KeyCode.keypadSet.contains(macro.chord.keyCode))
        }
    }

    @Test("KeyCode keypad + function sets are complete and disjoint")
    func keyCodeSets() {
        #expect(KeyCode.keypadSet.count == 18)
        #expect(KeyCode.functionKeySet.count == 12)
        #expect(KeyCode.keypadSet.isDisjoint(with: KeyCode.functionKeySet))
        // A chord flagged from these sets lands in the always-fire tiers.
        #expect(MacroEngine.tier(for: KeyChord(keyCode: KeyCode.f5, isFunctionKey: true)) == .chord)
        #expect(MacroEngine.tier(for: KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)) == .keypad)
    }

    // MARK: - Codable

    @Test("A macro round-trips through JSON, modifiers encoded as a bare int")
    func codableRoundTrip() throws {
        let macro = Macro(
            name: "Juke",
            chord: KeyChord(
                keyCode: 38,
                modifiers: [.command, .shift],
                isKeypad: false,
                isFunctionKey: false
            ),
            action: .script("juke()"),
            enabled: true,
            label: "Juke"
        )
        let data = try JSONEncoder().encode(macro)
        let decoded = try JSONDecoder().decode(Macro.self, from: data)
        #expect(decoded == macro)

        // modifiers serialize compactly (bare integer, not a wrapper object):
        // .command (1) | .shift (8) == 9.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"modifiers\":9"))
    }

    // MARK: - Shared tier gate (#40)

    @Test("chordMayFire: modifier/function/keypad always fire; bare needs nav+empty")
    func chordMayFireTierGate() {
        let modifier = KeyChord(keyCode: 38, modifiers: [.command])
        let function = KeyChord(keyCode: KeyCode.f1, isFunctionKey: true)
        let keypad = KeyChord(keyCode: KeyCode.keypad8, isKeypad: true)
        let bare = KeyChord(keyCode: 38)

        // Always-fire tiers ignore the context.
        for chord in [modifier, function, keypad] {
            #expect(MacroEngine.chordMayFire(chord, context: MacroContext()))
            #expect(MacroEngine.chordMayFire(
                chord, context: MacroContext(inputIsEmpty: false, navigationModeOn: false)
            ))
        }
        // A bare key fires only with Navigation mode on AND an empty input line.
        #expect(MacroEngine.chordMayFire(
            bare, context: MacroContext(inputIsEmpty: true, navigationModeOn: true)
        ))
        #expect(!MacroEngine.chordMayFire(
            bare, context: MacroContext(inputIsEmpty: true, navigationModeOn: false)
        ))
        #expect(!MacroEngine.chordMayFire(
            bare, context: MacroContext(inputIsEmpty: false, navigationModeOn: true)
        ))
    }
}
