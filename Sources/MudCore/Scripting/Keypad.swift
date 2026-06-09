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

/// The physical numeric-keypad keys, in grid order.
public enum KeypadKey: String, Codable, Sendable, Equatable, CaseIterable {
    case num0, num1, num2, num3, num4, num5, num6, num7, num8, num9
    case divide, multiply, subtract, add, decimal

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
}
