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
    /// The open quest, if any (`quest_target` with `qstat` 2/3); `nil` off-quest.
    public var quest: Quest?
    /// True when a new quest can be requested now (`quest_target.qstat == "0"`).
    public var canRequestQuest = false
    /// The joined global-quest id, when on a GQ.
    public var gqId: String?
    /// Unix time when a new quest can be requested (drives the cooldown countdown
    /// while off-quest waiting, `quest.status == "1"`).
    public var nextQuestTime: Double?

    /// The current quest target (reference `quest_target`).
    public struct Quest: Sendable, Equatable, Codable {
        /// `quest_target.qstat`: "1" off/cooldown, "2" on-quest target alive,
        /// "3" on-quest target killed (the bridge only sends it on 2/3/0/1).
        public var status: String?
        public var mob: String?
        public var area: String? // area keyword (arid)
        public var areaName: String?
        public var room: String?
        /// The quest target has been killed — return to complete (`qstat == "3"`).
        public var killed: Bool

        enum CodingKeys: String, CodingKey {
            case status, mob, area, room, killed
            case areaName = "area_name"
        }
    }

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
        case targets, quest
        case canRequestQuest = "can_request_quest"
        case gqId = "gq_id"
        case nextQuestTime = "next_quest_time"
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
        quest = try container.decodeIfPresent(Quest.self, forKey: .quest)
        canRequestQuest = try container.decodeIfPresent(Bool.self, forKey: .canRequestQuest) ?? false
        gqId = try container.decodeIfPresent(String.self, forKey: .gqId)
        nextQuestTime = try container.decodeIfPresent(Double.self, forKey: .nextQuestTime)
    }
}

public extension SearchAndDestroyModel.Quest {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        mob = try container.decodeIfPresent(String.self, forKey: .mob)
        area = try container.decodeIfPresent(String.self, forKey: .area)
        areaName = try container.decodeIfPresent(String.self, forKey: .areaName)
        room = try container.decodeIfPresent(String.self, forKey: .room)
        killed = try container.decodeIfPresent(Bool.self, forKey: .killed) ?? false
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
