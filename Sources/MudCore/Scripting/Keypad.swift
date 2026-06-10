import Foundation

/// The numeric-keypad command grid — a first-class Proteles feature, kept
/// **separate from macros** (mirroring how MUSHclient and the user think about
/// it): each numpad key sends a command. Surfaced as its own grid editor; backs
/// the keypad import.
public struct Keypad: Codable, Sendable, Equatable {
    /// Master on/off for keypad sending (MUSHclient's "Enable Keypad Keys").
    public var enabled: Bool
    public var bindings: [KeypadBinding]

    public init(enabled: Bool = true, bindings: [KeypadBinding] = []) {
        self.enabled = enabled
        self.bindings = bindings
    }

    /// The command bound to `key`, if any.
    public func command(for key: KeypadKey) -> String? {
        bindings.first { $0.key == key }?.command
    }

    /// The action a keypress should fire, or `nil` when the keypad is off,
    /// the chord isn't a bare keypad key (modifier combos stay free for
    /// macros), or the key is unbound. The runtime layer behind macros in
    /// the key-monitor precedence (macros → keypad → button hotkeys, D-102).
    public func action(for chord: KeyChord) -> MacroAction? {
        guard enabled, chord.isKeypad, chord.modifiers.isEmpty,
              let key = KeypadKey(keyCode: chord.keyCode),
              let command = command(for: key), !command.isEmpty
        else { return nil }
        return .command(command)
    }

    /// The shipped default layout — the Aardwolf navigation set (D-50,
    /// no diagonals), as keypad bindings. Seeded on a fresh profile and
    /// restorable from the Keypad editor.
    public static var defaultNavigation: Keypad {
        Keypad(enabled: true, bindings: [
            KeypadBinding(key: .num8, command: "north"),
            KeypadBinding(key: .num2, command: "south"),
            KeypadBinding(key: .num4, command: "west"),
            KeypadBinding(key: .num6, command: "east"),
            KeypadBinding(key: .num5, command: "look"),
            KeypadBinding(key: .num0, command: "scan"),
            KeypadBinding(key: .subtract, command: "up"),
            KeypadBinding(key: .add, command: "down"),
            KeypadBinding(key: .decimal, command: "score"),
            KeypadBinding(key: .divide, command: "inv"),
            KeypadBinding(key: .multiply, command: "eq")
        ])
    }
}

/// One keypad cell: a numpad key → the command it sends.
public struct KeypadBinding: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var key: KeypadKey
    public var command: String

    public init(id: UUID = UUID(), key: KeypadKey, command: String) {
        self.id = id
        self.key = key
        self.command = command
    }
}

/// The physical numeric-keypad keys, in grid order. Beyond MUSHclient's 15,
/// the Mac keypad's Clear and `=` are bindable too (D-102) — the import just
/// never fills them. Keypad Enter is deliberately absent: it submits the
/// command line.
public enum KeypadKey: String, Codable, Sendable, Equatable, CaseIterable {
    case num0, num1, num2, num3, num4, num5, num6, num7, num8, num9
    case divide, multiply, subtract, add, decimal
    case clear, equals

    /// MUSHclient `<key name>` label → key.
    private static let byLabel: [String: KeypadKey] = [
        "0": .num0, "1": .num1, "2": .num2, "3": .num3, "4": .num4,
        "5": .num5, "6": .num6, "7": .num7, "8": .num8, "9": .num9,
        "/": .divide, "*": .multiply, "-": .subtract, "+": .add, ".": .decimal
    ]

    /// Map a MUSHclient `<key name>` label (`"0"`–`"9"`, `"/"`, `"*"`, `"-"`,
    /// `"+"`, `"."`) to a key. Returns nil for an unrecognised label.
    public init?(mushclientLabel: String) {
        guard let key = Self.byLabel[mushclientLabel] else { return nil }
        self = key
    }

    /// The macOS virtual key code for this key (see ``KeyCode``).
    public var keyCode: UInt16 {
        switch self {
        case .num0: KeyCode.keypad0
        case .num1: KeyCode.keypad1
        case .num2: KeyCode.keypad2
        case .num3: KeyCode.keypad3
        case .num4: KeyCode.keypad4
        case .num5: KeyCode.keypad5
        case .num6: KeyCode.keypad6
        case .num7: KeyCode.keypad7
        case .num8: KeyCode.keypad8
        case .num9: KeyCode.keypad9
        case .divide: KeyCode.keypadDivide
        case .multiply: KeyCode.keypadMultiply
        case .subtract: KeyCode.keypadMinus
        case .add: KeyCode.keypadPlus
        case .decimal: KeyCode.keypadDecimal
        case .clear: KeyCode.keypadClear
        case .equals: KeyCode.keypadEquals
        }
    }

    private static let byKeyCode: [UInt16: KeypadKey] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.keyCode, $0) })

    /// Map a macOS virtual key code back to a key (nil for non-keypad codes
    /// and keypad Enter).
    public init?(keyCode: UInt16) {
        guard let key = Self.byKeyCode[keyCode] else { return nil }
        self = key
    }
}
