import Foundation

/// A snapshot of the Consider feature's state for the floating panel to render —
/// the mob list plus the controls' current values. Passed by value (no JSON),
/// mirroring how `.updateMap` ships captured map lines.
public struct ConsiderSnapshot: Sendable, Equatable {
    public var mobs: [ConsiderMob]
    public var defaultCommand: String
    public var executeMode: ConsiderExecuteMode
    public var auto: ConsiderAutoMode
    public var options: ConsiderBatchOptions
    /// A one-line status shown instead of the list (`"Safe room"`,
    /// `"Ignoring zone <x>"`), or nil when the list is live.
    public var statusNote: String?

    public init(
        mobs: [ConsiderMob] = [],
        defaultCommand: String = "kill",
        executeMode: ConsiderExecuteMode = .skill,
        auto: ConsiderAutoMode = .on,
        options: ConsiderBatchOptions = ConsiderBatchOptions(),
        statusNote: String? = nil
    ) {
        self.mobs = mobs
        self.defaultCommand = defaultCommand
        self.executeMode = executeMode
        self.auto = auto
        self.options = options
        self.statusNote = statusNote
    }
}

/// When the Consider list refreshes itself (`conw on|area|off`). An automatic
/// refresh fires on entering a room, when a mob arrives or flees, and when
/// the area repops; never mid-combat (it waits for the fight to end), while
/// running, or in a safe room.
public enum ConsiderAutoMode: String, Sendable, Equatable, Codable {
    /// Everywhere. The default: on a phone, typing a command per area costs
    /// more than the refresh does.
    case on
    /// Until the player leaves this area, then off, as Areia_Consider does
    /// ("to cut down on people spamming groups").
    case area
    /// Only on demand (`conw`, the panel's refresh). A consider the player or
    /// S&D sends still refreshes the list.
    case off
}

/// The persisted slice of the feature's configuration (survives reloads / world
/// reopen — the plugin's `save_state`).
struct ConsiderSettings: Codable, Equatable {
    var defaultCommand = "kill"
    var executeMode = ConsiderExecuteMode.skill
    var auto = ConsiderAutoMode.on
    var options = ConsiderBatchOptions()

    private enum CodingKeys: String, CodingKey {
        case defaultCommand, executeMode, auto, options
    }

    /// The settings before the modes: an on/off switch, with room entry and
    /// combat end as separate triggers.
    private enum LegacyKeys: String, CodingKey {
        case enabled, autoOnEntry
    }
}

extension ConsiderSettings {
    /// Settings saved before the modes become `on` when auto-refresh on room
    /// entry was on, else `off`. Their combat-end switch is dropped: a refresh
    /// after every kill replaced a list whose dead mobs the kill lines had
    /// already marked.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ConsiderSettings()
        defaultCommand = try container.decodeIfPresent(String.self, forKey: .defaultCommand)
            ?? defaults.defaultCommand
        executeMode = try container.decodeIfPresent(ConsiderExecuteMode.self, forKey: .executeMode)
            ?? defaults.executeMode
        options = try container.decodeIfPresent(ConsiderBatchOptions.self, forKey: .options)
            ?? defaults.options
        if let auto = try container.decodeIfPresent(ConsiderAutoMode.self, forKey: .auto) {
            self.auto = auto
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let enabled = try legacy.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            let onEntry = try legacy.decodeIfPresent(Bool.self, forKey: .autoOnEntry) ?? true
            auto = enabled && onEntry ? .on : .off
        }
    }
}
