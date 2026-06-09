import Foundation

/// Maps a parsed MUSHclient `<keypad>` into Proteles' ``Keypad`` model. Pure.
public enum MUSHclientKeypadMapping {
    /// Build a ``Keypad`` from the world's keypad keys. Unrecognised key labels
    /// and empty commands are dropped.
    public static func keypad(
        from keys: [MUSHclientWorldFile.KeypadKey],
        enabled: Bool = true
    ) -> Keypad {
        let bindings = keys.compactMap { entry -> KeypadBinding? in
            let command = entry.send.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = KeypadKey(mushclientLabel: entry.key), !command.isEmpty else { return nil }
            return KeypadBinding(key: key, command: command)
        }
        return Keypad(enabled: enabled, bindings: bindings)
    }
}
