import Foundation

/// Shared disk behaviour for the hand-editable `Settings/*.json` configs
/// (`soundpack.json`, `speech.json`, …) — issue #58's dedup of the
/// byte-identical load/save that SoundpackConfig and SpeechConfig grew
/// independently.
///
/// The contract every conformer inherits:
/// - **Loading is tolerant**: a missing *or malformed* file is the defaults
///   (`Self()`). A hand-edit must never brick the feature; conformers surface
///   parse trouble through their own debug channels, not errors.
/// - **Saving is pretty + sorted** (like every `Settings/*.json`), atomic, and
///   creates the parent directory on demand. Save failures are silent — these
///   are preference mirrors, never the only copy of session data.
public protocol SettingsFileBacked: Codable, Sendable {
    /// The defaults a missing/malformed file decodes to.
    init()
    /// The file's name under `Settings/`, e.g. `"soundpack.json"`.
    static var settingsFileName: String { get }
}

public extension SettingsFileBacked {
    /// `Settings/<settingsFileName>`.
    static func defaultURL() throws -> URL {
        try ProtelesPaths.settingsDirectory().appendingPathComponent(settingsFileName)
    }

    /// Load from `url`; a missing or malformed file (or a `nil` URL) is the
    /// defaults.
    static func load(from url: URL?) -> Self {
        guard let url, let data = FileManager.default.contents(atPath: url.path),
              let decoded = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return decoded
    }

    /// Persist to `url` (pretty + sorted keys, atomic write).
    func save(to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
