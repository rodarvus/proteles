import Foundation

/// `CreateGUID()` / `GetUniqueID()` — the two id-string world functions
/// (`methods_utilities.cpp` → `GetGUID` / `GetUniqueID` in `Utilities.cpp`).
///
/// Both values are random (MUSHclient seeds them from `CoCreateGuid`), so no
/// plugin can observe a specific value — the faithful contract is the *format*
/// plus uniqueness, which is what we match:
///   - `CreateGUID` → an uppercase, dash-separated GUID (`8-4-4-4-12`), exactly
///     `GetGUID`'s `%08lX-%04X-…` layout. `UUID().uuidString` already is that.
///   - `GetUniqueID` → 24 lowercase hex chars (`PLUGIN_UNIQUE_ID_LENGTH`).
///     MUSHclient SHA-hashes a dash-stripped GUID and keeps the first three
///     32-bit words; we draw 12 random bytes directly — same length, same
///     alphabet, same (cryptographic) uniqueness.
public enum ScriptIdentifiers {
    public static func createGUID() -> String {
        UUID().uuidString
    }

    public static func uniqueID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<12)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }
}
