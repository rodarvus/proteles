import Foundation

/// The decoded Search-and-Destroy display model — what S&D publishes (via the
/// `xg_draw_window` bridge) for the native panel to render. Mirrors the JSON
/// snapshot's shape; all fields tolerate omission so partial state still
/// decodes.
public struct SearchAndDestroyModel: Sendable, Equatable, Codable {
    public var version: String?
    public var activity: String? // "cp" | "gq" | "quest" | "none" | "init"
    public var playerOnCP: Bool
    public var playerOnGQ: Bool
    public var targetCount: Int
    public var targets: [Target]

    public struct Target: Sendable, Equatable, Codable, Identifiable {
        public var index: Int
        public var mob: String?
        public var room: String?
        public var area: String?
        public var location: String?
        public var linkType: String? // "area" | "room" | "unknown"
        public var qty: Int? // gquest kill count
        public var duplicates: Int? // total instances of this mob
        public var dupIndex: Int? // which instance
        public var unlikely: Bool
        public var express: Bool
        public var current: Bool
        public var dead: Bool

        public var id: Int {
            index
        }

        enum CodingKeys: String, CodingKey {
            case index, mob, room, area, location
            case linkType = "link_type"
            case qty, duplicates
            case dupIndex = "dup_index"
            case unlikely, express, current, dead
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, activity
        case playerOnCP = "player_on_cp"
        case playerOnGQ = "player_on_gq"
        case targetCount = "target_count"
        case targets
    }

    /// Decode a published JSON snapshot, or nil if it isn't valid.
    public static func decode(_ json: String) -> SearchAndDestroyModel? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SearchAndDestroyModel.self, from: data)
    }

    /// The human label for the current activity.
    public var activityLabel: String {
        switch activity {
        case "cp": "Campaign"
        case "gq": "Global Quest"
        case "quest": "Quest"
        case "none": "Idle"
        default: "—"
        }
    }
}

/// Defaults so partial JSON (missing booleans/arrays) still decodes.
public extension SearchAndDestroyModel {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        playerOnCP = try container.decodeIfPresent(Bool.self, forKey: .playerOnCP) ?? false
        playerOnGQ = try container.decodeIfPresent(Bool.self, forKey: .playerOnGQ) ?? false
        targetCount = try container.decodeIfPresent(Int.self, forKey: .targetCount) ?? 0
        // An empty Lua table serialises to `{}` (object), not `[]`; tolerate
        // that by falling back to an empty list.
        targets = (try? container.decode([Target].self, forKey: .targets)) ?? []
    }
}

public extension SearchAndDestroyModel.Target {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        mob = try container.decodeIfPresent(String.self, forKey: .mob)
        room = try container.decodeIfPresent(String.self, forKey: .room)
        area = try container.decodeIfPresent(String.self, forKey: .area)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        linkType = try container.decodeIfPresent(String.self, forKey: .linkType)
        qty = try container.decodeIfPresent(Int.self, forKey: .qty)
        duplicates = try container.decodeIfPresent(Int.self, forKey: .duplicates)
        dupIndex = try container.decodeIfPresent(Int.self, forKey: .dupIndex)
        unlikely = try container.decodeIfPresent(Bool.self, forKey: .unlikely) ?? false
        express = try container.decodeIfPresent(Bool.self, forKey: .express) ?? false
        current = try container.decodeIfPresent(Bool.self, forKey: .current) ?? false
        dead = try container.decodeIfPresent(Bool.self, forKey: .dead) ?? false
    }
}
