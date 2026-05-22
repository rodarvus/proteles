import Foundation

// Typed Aardwolf GMCP modules (PLAN.md §5.5). Field names match exactly
// what Aardwolf sends on the wire (verified against
// aardwolfclientpackage's aard_statmon_gmcp.xml). Values arrive as JSON
// numbers; non-essential fields are optional so a partial payload still
// decodes. Unknown keys are ignored by `Codable`.

/// `Char.Vitals` — current HP / mana / moves. Sent every change / tick;
/// drives the status-bar gauges.
public struct CharVitals: Codable, Sendable, Equatable {
    public let hp: Int
    public let mana: Int
    public let moves: Int

    public init(hp: Int, mana: Int, moves: Int) {
        self.hp = hp
        self.mana = mana
        self.moves = moves
    }
}

/// `Char.MaxStats` — maxima for the vitals (and the trainable stats,
/// which we keep optional and unused for now).
public struct CharMaxStats: Codable, Sendable, Equatable {
    public let maxhp: Int
    public let maxmana: Int
    public let maxmoves: Int
    public let maxstr: Int?
    public let maxint: Int?
    public let maxwis: Int?
    public let maxdex: Int?
    public let maxcon: Int?
    public let maxluck: Int?

    public init(
        maxhp: Int,
        maxmana: Int,
        maxmoves: Int,
        maxstr: Int? = nil,
        maxint: Int? = nil,
        maxwis: Int? = nil,
        maxdex: Int? = nil,
        maxcon: Int? = nil,
        maxluck: Int? = nil
    ) {
        self.maxhp = maxhp
        self.maxmana = maxmana
        self.maxmoves = maxmoves
        self.maxstr = maxstr
        self.maxint = maxint
        self.maxwis = maxwis
        self.maxdex = maxdex
        self.maxcon = maxcon
        self.maxluck = maxluck
    }
}

/// `Char.Status` — level, experience-to-next-level, alignment, and the
/// current enemy (during combat).
public struct CharStatus: Codable, Sendable, Equatable {
    public let level: Int
    public let tnl: Int?
    public let align: Int?
    public let enemy: String?
    public let enemypct: Int?

    public init(
        level: Int,
        tnl: Int? = nil,
        align: Int? = nil,
        enemy: String? = nil,
        enemypct: Int? = nil
    ) {
        self.level = level
        self.tnl = tnl
        self.align = align
        self.enemy = enemy
        self.enemypct = enemypct
    }
}

/// `Char.Worth` — currencies and trainable resources.
public struct CharWorth: Codable, Sendable, Equatable {
    public let gold: Int?
    public let qp: Int?
    public let tp: Int?
    public let trains: Int?
    public let pracs: Int?

    public init(
        gold: Int? = nil,
        qp: Int? = nil,
        tp: Int? = nil,
        trains: Int? = nil,
        pracs: Int? = nil
    ) {
        self.gold = gold
        self.qp = qp
        self.tp = tp
        self.trains = trains
        self.pracs = pracs
    }
}

/// `Char.Base` — identity sent once at login: name, class, race. Used for
/// the class/race label in the status bar.
public struct CharBase: Codable, Sendable, Equatable {
    public let name: String?
    public let `class`: String?
    public let subclass: String?
    public let race: String?
    public let sex: String?

    public init(
        name: String? = nil,
        class: String? = nil,
        subclass: String? = nil,
        race: String? = nil,
        sex: String? = nil
    ) {
        self.name = name
        self.class = `class`
        self.subclass = subclass
        self.race = race
        self.sex = sex
    }
}

/// `Room.Info` — the current room. `name` carries Aardwolf `@`-colour
/// codes (strip with ``AardwolfColor/stripped(_:)`` for plain display).
/// `exits` maps a direction (`n`, `s`, `u`, …) to the destination room
/// number. `zone` is Aardwolf's area name.
public struct RoomInfo: Codable, Sendable, Equatable {
    public let num: Int
    public let name: String
    public let zone: String?
    public let terrain: String?
    public let details: String?
    public let exits: [String: Int]?
    public let coord: Coord?

    public struct Coord: Codable, Sendable, Equatable {
        public let id: Int?
        public let x: Int?
        public let y: Int?
        public let cont: Int?

        public init(id: Int? = nil, x: Int? = nil, y: Int? = nil, cont: Int? = nil) {
            self.id = id
            self.x = x
            self.y = y
            self.cont = cont
        }
    }

    public init(
        num: Int,
        name: String,
        zone: String? = nil,
        terrain: String? = nil,
        details: String? = nil,
        exits: [String: Int]? = nil,
        coord: Coord? = nil
    ) {
        self.num = num
        self.name = name
        self.zone = zone
        self.terrain = terrain
        self.details = details
        self.exits = exits
        self.coord = coord
    }
}
