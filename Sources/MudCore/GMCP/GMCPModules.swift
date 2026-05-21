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
}

/// `Char.Status` — level, experience-to-next-level, alignment, and the
/// current enemy (during combat).
public struct CharStatus: Codable, Sendable, Equatable {
    public let level: Int
    public let tnl: Int?
    public let align: Int?
    public let enemy: String?
    public let enemypct: Int?
}

/// `Char.Worth` — currencies and trainable resources.
public struct CharWorth: Codable, Sendable, Equatable {
    public let gold: Int?
    public let qp: Int?
    public let tp: Int?
    public let trains: Int?
    public let pracs: Int?
}

/// `Char.Base` — identity sent once at login: name, class, race. Used for
/// the class/race label in the status bar.
public struct CharBase: Codable, Sendable, Equatable {
    public let name: String?
    public let `class`: String?
    public let subclass: String?
    public let race: String?
    public let sex: String?
}
