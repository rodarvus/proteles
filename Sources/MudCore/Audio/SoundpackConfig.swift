import Foundation

/// The soundpack's user configuration (#10), stored hand-editably in
/// `Settings/soundpack.json` (the notification-rules pattern — global, not
/// per-world: cue preferences follow the player, not the profile). Defaults
/// live in code (``SoundEventClassifier/defaults``); this file records only
/// deviations, so a fresh install writes nothing until the first change.
///
/// Faithful to the reference's persisted variables: `muted` is MUSHclient's
/// `sp_mute_toggle` (**muted by default** — the soundpack has always been
/// opt-in; `spmute` or the Audio settings enable it), `globalVolume` is
/// `sp_global_volume` (a 0–100 cap applied over per-event volumes), and each
/// event override carries `volume` (0 disables the event), `pan` (−100…100),
/// and/or a custom `file`.
public struct SoundpackConfig: Codable, Sendable, Equatable {
    /// One event's deviations from the defaults (volume 100, pan 0, the
    /// reference wav). All-nil overrides are pruned on save.
    public struct EventOverride: Codable, Sendable, Equatable {
        public var volume: Int?
        public var pan: Int?
        public var file: String?

        public init(volume: Int? = nil, pan: Int? = nil, file: String? = nil) {
            self.volume = volume
            self.pan = pan
            self.file = file
        }

        var isEmpty: Bool {
            volume == nil && pan == nil && file == nil
        }
    }

    public var muted = true
    public var globalVolume = 100
    public var debug = false
    /// When an event's cue file can't be found anywhere, play a mapped macOS
    /// system alert instead (the app-side fallback tier) — on by default so
    /// the feature isn't silent before any sounds are imported.
    public var systemSoundFallback = true
    public var events: [String: EventOverride] = [:]

    public init() {}

    /// Tolerant decoding for hand-edited files: every missing key keeps its
    /// default, so a file containing just `{"muted": false}` is valid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        globalVolume = try container.decodeIfPresent(Int.self, forKey: .globalVolume) ?? 100
        debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        systemSoundFallback = try container.decodeIfPresent(Bool.self, forKey: .systemSoundFallback) ?? true
        events = try container.decodeIfPresent([String: EventOverride].self, forKey: .events) ?? [:]
    }

    // MARK: - Effective per-event values

    /// The event's effective volume percent (0 = disabled).
    public func volume(for event: String) -> Int {
        events[event]?.volume ?? 100
    }

    /// The event's effective pan (−100…100).
    public func pan(for event: String) -> Int {
        events[event]?.pan ?? 0
    }

    /// The event's cue filename: the custom override, else the reference
    /// default. `nil` for an unknown event.
    public func file(for event: String) -> String? {
        events[event]?.file ?? SoundEventClassifier.defaults[event]?.file
    }

    /// Mutate one event's override, pruning it when it returns to defaults.
    public mutating func updateOverride(for event: String, _ change: (inout EventOverride) -> Void) {
        var override = events[event] ?? EventOverride()
        change(&override)
        events[event] = override.isEmpty ? nil : override
    }

    // MARK: - Disk

    /// `Settings/soundpack.json`.
    public static func defaultURL() throws -> URL {
        try ProtelesPaths.settingsDirectory().appendingPathComponent("soundpack.json")
    }

    /// Load from `url`; a missing or malformed file is the defaults (the
    /// malformed case is surfaced by the plugin's `spdebug`, not an error —
    /// a hand-edit must never brick the soundpack).
    public static func load(from url: URL?) -> SoundpackConfig {
        guard let url, let data = FileManager.default.contents(atPath: url.path),
              let decoded = try? JSONDecoder().decode(SoundpackConfig.self, from: data)
        else { return SoundpackConfig() }
        return decoded
    }

    /// Persist to `url` (pretty + sorted, like every Settings/*.json).
    public func save(to url: URL?) {
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
