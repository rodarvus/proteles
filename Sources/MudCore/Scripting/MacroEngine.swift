import Foundation

/// The modifier keys a ``KeyChord`` can carry. Mirrors the AppKit
/// `NSEvent.ModifierFlags` we care about, but defined here so the engine
/// stays platform-neutral (no AppKit import) and unit-testable. ⇧ is tracked
/// but, on its own, never promotes a key out of the "bare" tier — a
/// shift+letter is just uppercase typing (see ``MacroEngine/tier(for:)``).
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// Any of ⌘/⌥/⌃ — the modifiers that make a key safe to bind without
    /// conflicting with text entry. ⇧ deliberately excluded.
    public var hasCommandOptionControl: Bool {
        !isDisjoint(with: [.command, .option, .control])
    }

    /// Encode as a bare integer rather than `{ "rawValue": N }`.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A key (or key combination) that can fire a macro. Identity is the raw
/// platform key code plus modifiers and two flags the platform layer can
/// distinguish (numeric keypad, function row) — so the engine never has to
/// reason about specific key codes and stays testable without AppKit.
///
/// `keyCode` is opaque to the engine; on macOS it is the Carbon virtual key
/// code (`kVK_*`) the app's key monitor reports. See ``KeyCode`` for the
/// named constants the shipped defaults use.
public struct KeyChord: Sendable, Hashable, Codable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    /// The key came from the numeric keypad (distinct key codes on macOS).
    public var isKeypad: Bool
    /// The key is a function key (F1–F12) — never conflicts with typing.
    public var isFunctionKey: Bool

    public init(
        keyCode: UInt16,
        modifiers: KeyModifiers = [],
        isKeypad: Bool = false,
        isFunctionKey: Bool = false
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isKeypad = isKeypad
        self.isFunctionKey = isFunctionKey
    }
}

/// What a macro does when it fires. Kept deliberately small and reusable so
/// the same value can back both a key chord *and* a future command-button bar
/// (Mudlet's TAction) — see MACRO_ENGINE_PLAN.md.
public enum MacroAction: Sendable, Equatable, Hashable, Codable {
    /// Run through the input pipeline as if typed (so `;`-stacking and
    /// aliases apply).
    case command(String)
    /// Run as Lua in the user script environment.
    case script(String)
    /// Put the text in the command line **without sending** — the user finishes
    /// typing and presses Enter. MUSHclient's `replace`-type macro (e.g. a `say `
    /// prefix). Handled by the input field; a no-op when fired programmatically.
    case replaceInput(String)
}

/// A key bound to an action, persisted per world alongside triggers/aliases/
/// timers (see ``ScriptDocument``). A pure value type — matching lives in
/// ``MacroEngine``, action execution in the host.
public struct Macro: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    /// Optional human name (also the default button label).
    public var name: String?
    public var chord: KeyChord
    public var action: MacroAction
    public var enabled: Bool
    /// Display label for a command-button bar; `nil` falls back to ``name``.
    public var label: String?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        chord: KeyChord,
        action: MacroAction,
        enabled: Bool = true,
        label: String? = nil
    ) {
        self.id = id
        self.name = name
        self.chord = chord
        self.action = action
        self.enabled = enabled
        self.label = label
    }
}

/// The live state the engine needs to decide whether a *bare* key may fire
/// (tier 3). The platform layer supplies this on each keypress.
public struct MacroContext: Sendable, Equatable {
    /// The command input is empty (no half-typed line to clobber).
    public var inputIsEmpty: Bool
    /// The opt-in "Navigation mode" is on.
    public var navigationModeOn: Bool

    public init(inputIsEmpty: Bool = false, navigationModeOn: Bool = false) {
        self.inputIsEmpty = inputIsEmpty
        self.navigationModeOn = navigationModeOn
    }
}

/// How risky a chord is to bind, by conflict with text entry
/// (MACRO_ENGINE_PLAN.md "The one-key conflict").
public enum MacroTier: Sendable, Equatable {
    /// Modifier chord (⌘/⌥/⌃) or function key — never conflicts; always fires.
    case chord
    /// Numeric keypad key — distinguishable from the main row; always fires.
    case keypad
    /// Bare main-keyboard key — conflicts with typing; fires only when
    /// Navigation mode is on *and* the input is empty.
    case bare
}

/// Matches a keypress against a set of ``Macro``s (MACRO_ENGINE_PLAN.md).
///
/// Like ``AliasEngine``/``TriggerEngine`` this is pure lookup: ``match`` decides
/// *whether* a macro fires (applying the tier rules against the supplied
/// ``MacroContext``) and returns it; the host runs the ``MacroAction`` and
/// swallows the event. A chord maps to at most one macro — the first enabled
/// one in insertion order.
public struct MacroEngine {
    private var macros: [Macro]

    public init(_ macros: [Macro] = []) {
        self.macros = macros
    }

    public var allMacros: [Macro] {
        macros
    }

    public mutating func add(_ macro: Macro) {
        macros.append(macro)
    }

    public mutating func remove(id: UUID) {
        macros.removeAll { $0.id == id }
    }

    public mutating func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = macros.firstIndex(where: { $0.id == id }) else { return }
        macros[index].enabled = enabled
    }

    /// Replace the whole set (e.g. after loading a ``ScriptDocument``).
    public mutating func replaceAll(_ macros: [Macro]) {
        self.macros = macros
    }

    /// Classify a chord into its conflict tier. Pure function of the chord.
    public static func tier(for chord: KeyChord) -> MacroTier {
        if chord.modifiers.hasCommandOptionControl { return .chord }
        if chord.isFunctionKey { return .chord }
        if chord.isKeypad { return .keypad }
        return .bare
    }

    /// Whether a chord may fire *right now* given its tier and the context — a
    /// modifier/function/keypad chord always may; a bare main-keyboard key only
    /// when Navigation mode is on *and* the input is empty. The shared gate used
    /// by both macro matching and command-button hotkeys (#40), so they agree.
    public static func chordMayFire(_ chord: KeyChord, context: MacroContext) -> Bool {
        switch tier(for: chord) {
        case .chord, .keypad:
            true
        case .bare:
            context.navigationModeOn && context.inputIsEmpty
        }
    }

    /// The macro that should fire for `chord` given `context`, or `nil` if
    /// none is bound or its tier forbids firing right now (a bare key with
    /// Navigation mode off or a non-empty input line).
    public func match(_ chord: KeyChord, context: MacroContext) -> Macro? {
        guard let macro = macros.first(where: { $0.enabled && $0.chord == chord }),
              Self.chordMayFire(chord, context: context)
        else { return nil }
        return macro
    }
}

/// macOS Carbon virtual key codes (`kVK_*`) for the keys the shipped macro
/// defaults reference. The engine treats key codes as opaque; these named
/// constants just keep ``MacroEngine/defaultNavigationMacros()`` readable and
/// give the app's key monitor a single source for the keypad set.
public enum KeyCode {
    public static let keypad0: UInt16 = 82
    public static let keypad1: UInt16 = 83
    public static let keypad2: UInt16 = 84
    public static let keypad3: UInt16 = 85
    public static let keypad4: UInt16 = 86
    public static let keypad5: UInt16 = 87
    public static let keypad6: UInt16 = 88
    public static let keypad7: UInt16 = 89
    public static let keypad8: UInt16 = 91
    public static let keypad9: UInt16 = 92
    public static let keypadDecimal: UInt16 = 65
    public static let keypadPlus: UInt16 = 69
    public static let keypadMinus: UInt16 = 78
    public static let keypadMultiply: UInt16 = 67
    public static let keypadDivide: UInt16 = 75
    public static let keypadEnter: UInt16 = 76
    public static let keypadEquals: UInt16 = 81
    public static let keypadClear: UInt16 = 71

    public static let f1: UInt16 = 122
    public static let f2: UInt16 = 120
    public static let f3: UInt16 = 99
    public static let f4: UInt16 = 118
    public static let f5: UInt16 = 96
    public static let f6: UInt16 = 97
    public static let f7: UInt16 = 98
    public static let f8: UInt16 = 100
    public static let f9: UInt16 = 101
    public static let f10: UInt16 = 109
    public static let f11: UInt16 = 103
    public static let f12: UInt16 = 111

    /// Every numeric-keypad key code, so the monitor can classify a keypress
    /// as ``KeyChord/isKeypad`` without trusting the `numericPad` modifier
    /// flag (macOS sets it for the arrow keys too).
    public static let keypadSet: Set<UInt16> = [
        keypad0, keypad1, keypad2, keypad3, keypad4,
        keypad5, keypad6, keypad7, keypad8, keypad9,
        keypadDecimal, keypadPlus, keypadMinus, keypadMultiply,
        keypadDivide, keypadEnter, keypadEquals, keypadClear
    ]

    /// F1–F12 key codes, so the monitor can mark a chord as
    /// ``KeyChord/isFunctionKey`` (the always-fire chord tier).
    public static let functionKeySet: Set<UInt16> = [
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    ]
}

public extension MacroEngine {
    /// The default keypad layout, seeded on first run (editable — not
    /// hardcoded behaviour). Reflects the canonical Aardwolf keypad mapping
    /// from the reference package's world file
    /// (`submodules/aardwolfclientpackage/MUSHclient/worlds/Aardwolf.mcl`, `<keypad>`):
    /// 8/2/4/6 cardinals, 5 look, 0 scan, `-` up, `+` down, `.` score,
    /// `/` inv, `*` eq. Keys 1/3/7/9 are intentionally unbound — Aardwolf has
    /// no diagonal movement (no ne/nw/se/sw).
    static func defaultNavigationMacros() -> [Macro] {
        func keypad(_ keyCode: UInt16, _ command: String, _ label: String) -> Macro {
            Macro(
                name: label,
                chord: KeyChord(keyCode: keyCode, isKeypad: true),
                action: .command(command),
                label: label
            )
        }
        return [
            keypad(KeyCode.keypad8, "north", "North"),
            keypad(KeyCode.keypad2, "south", "South"),
            keypad(KeyCode.keypad4, "west", "West"),
            keypad(KeyCode.keypad6, "east", "East"),
            keypad(KeyCode.keypad5, "look", "Look"),
            keypad(KeyCode.keypad0, "scan", "Scan"),
            keypad(KeyCode.keypadMinus, "up", "Up"),
            keypad(KeyCode.keypadPlus, "down", "Down"),
            keypad(KeyCode.keypadDecimal, "score", "Score"),
            keypad(KeyCode.keypadDivide, "inv", "Inventory"),
            keypad(KeyCode.keypadMultiply, "eq", "Equipment")
        ]
    }
}
