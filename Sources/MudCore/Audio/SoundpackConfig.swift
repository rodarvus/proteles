import Foundation

/// The event→cue map (#10, S1 step 2): which files an event plays, at what
/// volume and pan, under per-category caps and a master. Stored hand-editably
/// in `Settings/soundpack.json` (the notification-rules pattern — global, not
/// per-world: cue preferences follow the player, not the profile). Defaults
/// live in code (``SoundEventClassifier/defaults``, the reference's 69); this
/// file records only deviations, so a fresh install writes nothing until the
/// first change.
///
/// Faithful to the reference's persisted variables where it has them: `muted`
/// is MUSHclient's `sp_mute_toggle` (**muted by default** — the soundpack has
/// always been opt-in; `spmute` or the Audio settings enable it),
/// `globalVolume` is `sp_global_volume` (the master, a 0–100 cap), and each
/// event override carries `volume` (0 disables the event) and `pan`
/// (−100…100). Proteles adds what the reference lacks (D-127): **variants**
/// (`files`, one picked per firing) and **category volumes**, a third cap, so
/// a cue plays at `min(event, category, master)` and volumes tuned in
/// MUSHclient carry over unchanged.
///
/// Any first-party event name can carry files — the six tag-sourced events as
/// well as the reference's 69 — but only names in ``SemanticEventVocabulary``:
/// there are no user-defined events (D-122).
public struct SoundpackConfig: SettingsFileBacked, Equatable {
    /// The file format this type writes. Version 1 (≤ 0.8.x) had one `file`
    /// per event and no `version` key; see `SoundpackConfig+Migration.swift`.
    public static let currentVersion = 2

    /// One event's deviations from the defaults (volume 100, pan 0, the
    /// reference wav). All-nil overrides are pruned on save.
    public struct EventOverride: Codable, Sendable, Equatable {
        public var volume: Int?
        public var pan: Int?
        /// The event's cue files, replacing the default; one is picked per
        /// firing. `nil` keeps the default. Never empty: an empty list is
        /// pruned to `nil`, and `spset … wav remove` won't remove the last
        /// file (silencing is volume 0's job).
        public var files: [String]?

        public init(volume: Int? = nil, pan: Int? = nil, files: [String]? = nil) {
            self.volume = volume
            self.pan = pan
            self.files = files
        }

        var isEmpty: Bool {
            volume == nil && pan == nil && files == nil
        }
    }

    public var version = Self.currentVersion
    public var muted = true
    public var globalVolume = 100
    public var debug = false
    /// When an event's cue file can't be found anywhere, play a mapped macOS
    /// system alert instead (the app-side fallback tier) — on by default so
    /// the feature isn't silent before any sounds are imported.
    public var systemSoundFallback = true
    public var events: [String: EventOverride] = [:]
    /// Category volume deviations, keyed by ``SemanticEvent/Category`` raw
    /// value (`"combat"`, …). Absent = 100.
    public var categories: [String: Int] = [:]

    public init() {}

    /// Tolerant decoding for hand-edited files: every missing key keeps its
    /// default, so a file containing just `{"muted": false}` is valid.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        globalVolume = try container.decodeIfPresent(Int.self, forKey: .globalVolume) ?? 100
        debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        systemSoundFallback = try container.decodeIfPresent(Bool.self, forKey: .systemSoundFallback) ?? true
        events = try container.decodeIfPresent([String: EventOverride].self, forKey: .events) ?? [:]
        categories = try container.decodeIfPresent([String: Int].self, forKey: .categories) ?? [:]
    }

    // MARK: - The vocabulary a cue can key on

    /// Every event name the map accepts: the reference's 69 plus the rest of
    /// the first-party vocabulary (the tag-sourced events). Sorted, as `spset`
    /// lists them (the reference's `orderedPairs`).
    public static let eventNames: [String] = Set(SoundEventClassifier.defaults.keys)
        .union(SemanticEventVocabulary.categories.keys)
        .sorted()

    /// Whether `event` is a name the map accepts.
    public static func isKnown(_ event: String) -> Bool {
        SoundEventClassifier.defaults[event] != nil || SemanticEventVocabulary.category(for: event) != nil
    }

    // MARK: - Effective per-event values

    /// The event's own volume percent (0 = disabled).
    public func volume(for event: String) -> Int {
        events[event]?.volume ?? 100
    }

    /// The event's effective pan (−100…100).
    public func pan(for event: String) -> Int {
        events[event]?.pan ?? 0
    }

    /// The event's cue files: the override list, else the reference default,
    /// else none (a vocabulary event with no default sound).
    public func files(for event: String) -> [String] {
        if let files = events[event]?.files { return files }
        return SoundEventClassifier.defaults[event].map { [$0.file] } ?? []
    }

    /// A category's volume percent (100 unless set).
    public func volume(for category: SemanticEvent.Category) -> Int {
        categories[category.rawValue] ?? 100
    }

    /// The percent an event actually plays at: the lowest of its own volume,
    /// its category's, and the master (D-127). An event outside the
    /// vocabulary's categories is capped by its own volume and the master.
    public func effectiveVolume(for event: String) -> Int {
        let category = SemanticEventVocabulary.category(for: event).map { volume(for: $0) } ?? 100
        return min(volume(for: event), category, globalVolume)
    }

    // MARK: - The cue

    /// The cue `event` plays, and which of its files was picked — or nil when
    /// it has no files or plays at volume 0.
    ///
    /// With two or more files the pick never repeats `previousPick`: plain
    /// uniform choice replays the same file half the time with two variants,
    /// which sounds like having none. `random(n)` returns a value in `0..<n`
    /// (injectable for tests).
    public func cue(
        for event: String,
        previousPick: Int? = nil,
        random: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> (cue: SoundCue, pick: Int)? {
        let files = files(for: event)
        let percent = effectiveVolume(for: event)
        guard !files.isEmpty, percent > 0 else { return nil }
        let pick = Self.pick(count: files.count, avoiding: previousPick, random: random)
        let cue = SoundCue(
            file: files[pick],
            volume: SoundVolume.linearGain(forPercent: Double(percent)),
            pan: SoundVolume.pan(forMushPan: Double(pan(for: event))),
            event: event
        )
        return (cue, pick)
    }

    /// An index in `0..<count`, never `avoiding` when there is a choice.
    static func pick(count: Int, avoiding previous: Int?, random: (Int) -> Int) -> Int {
        guard count > 1 else { return 0 }
        guard let previous, (0..<count).contains(previous) else { return random(count) }
        let draw = random(count - 1)
        return draw >= previous ? draw + 1 : draw
    }

    // MARK: - Editing

    /// Mutate one event's override, pruning it when it returns to defaults.
    public mutating func updateOverride(for event: String, _ change: (inout EventOverride) -> Void) {
        var override = events[event] ?? EventOverride()
        change(&override)
        if override.files?.isEmpty == true { override.files = nil }
        events[event] = override.isEmpty ? nil : override
    }

    /// Set a category's volume, pruning it at 100.
    public mutating func setVolume(_ volume: Int, for category: SemanticEvent.Category) {
        categories[category.rawValue] = volume == 100 ? nil : volume
    }

    // MARK: - Disk

    /// Load/save via `SettingsFileBacked`; a malformed file is the defaults,
    /// surfaced by the plugin's `spdebug` rather than an error.
    public static let settingsFileName = "soundpack.json"
}
