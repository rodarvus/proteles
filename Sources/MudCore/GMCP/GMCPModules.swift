import Foundation

// Typed Aardwolf GMCP modules (ARCHITECTURE.md §5.5). Field names match exactly
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
    /// Aardwolf's player-state enum (verified against the live `char.status` +
    /// the reference mapper): `8` = fighting, `12` = running/speedwalking, `5` =
    /// note-mode (writing), `3`/`11` = active/standing. Optional (older fixtures
    /// omit it). Backs the auto-update mid-combat guard (#42 / D-100).
    public let state: Int?

    public init(
        level: Int,
        tnl: Int? = nil,
        align: Int? = nil,
        enemy: String? = nil,
        enemypct: Int? = nil,
        state: Int? = nil
    ) {
        self.level = level
        self.tnl = tnl
        self.align = align
        self.enemy = enemy
        self.enemypct = enemypct
        self.state = state
    }

    /// The current combat opponent and its remaining health percentage, or
    /// `nil` when not fighting — Aardwolf clears `enemy` to `""` out of combat
    /// and only sends `enemypct` while engaged. Backs the status-bar enemy
    /// gauge (the useful slice of `aard_health_bars_gmcp`).
    public var combatTarget: (name: String, percent: Int)? {
        guard let enemy, !enemy.isEmpty, let enemypct else { return nil }
        return (enemy, enemypct)
    }

    /// Whether it's a safe moment to interrupt with an update prompt (#42): not
    /// fighting (`8`) / running (`12`) / note-mode (`5`), and not engaged with a
    /// combat target. An unknown `state` falls back to the combat-target check.
    public var isSafeToInterrupt: Bool {
        if let state, state == 8 || state == 12 || state == 5 { return false }
        return combatTarget == nil
    }
}

/// `Char.Stats` — the trainable stats plus hit/damage roll, as Aardwolf's
/// statmon shows them. Sent on change; values arrive as JSON numbers.
public struct CharStats: Codable, Sendable, Equatable {
    public let str: Int
    public let int: Int
    public let wis: Int
    public let dex: Int
    public let con: Int
    public let luck: Int
    /// Hit roll.
    public let hr: Int
    /// Damage roll.
    public let dr: Int

    public init(str: Int, int: Int, wis: Int, dex: Int, con: Int, luck: Int, hr: Int, dr: Int) {
        self.str = str
        self.int = int
        self.wis = wis
        self.dex = dex
        self.con = con
        self.luck = luck
        self.hr = hr
        self.dr = dr
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
    /// Experience required to gain one level at the current level — the
    /// denominator for the TNL status bar (the numerator is
    /// ``CharStatus/tnl``). Aardwolf sends this in `char.base`
    /// (`gmcp_char.base.perlevel`, per `aard_health_bars_gmcp`).
    public let perlevel: Int?

    public init(
        name: String? = nil,
        class: String? = nil,
        subclass: String? = nil,
        race: String? = nil,
        sex: String? = nil,
        perlevel: Int? = nil
    ) {
        self.name = name
        self.class = `class`
        self.subclass = subclass
        self.race = race
        self.sex = sex
        self.perlevel = perlevel
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

/// `group` — the player's group. When grouped, ``members`` is populated;
/// when not, ``reason`` explains why (`"no group"`, `"quit"`, …).
///
/// Aardwolf sends each member's stats as **strings** inside `info` (the
/// reference plugin runs `tonumber()` on them), so ``Member/Info`` stores
/// strings and exposes parsed accessors.
/// Coding keys for ``GroupInfo/Member/Info`` (file-scoped so its custom decoder
/// — which accepts number-or-string member fields — doesn't nest a type too deep).
private enum GroupMemberInfoKey: String, CodingKey {
    case lvl, hp, mhp, mn, mmn, mv, mmv, tnl, align, here, qt, qs
}

public struct GroupInfo: Codable, Sendable, Equatable {
    public let groupname: String?
    public let leader: String?
    public let members: [Member]?
    public let reason: String?

    public var isGrouped: Bool {
        !(members ?? []).isEmpty
    }

    public struct Member: Codable, Sendable, Equatable, Identifiable {
        public let name: String
        public let info: Info?

        public var id: String {
            name
        }

        public struct Info: Codable, Sendable, Equatable {
            public let lvl: String?
            public let hp: String?
            public let mhp: String?
            public let mn: String?
            public let mmn: String?
            public let mv: String?
            public let mmv: String?
            public let tnl: String?
            public let align: String?
            public let here: String?
            /// Quest timer (minutes) and quest status (`"1"` = on a quest) — the
            /// per-member quest fields Aardwolf's `group` GMCP carries (read by
            /// the reference's group monitor). Optional → tolerated when absent.
            public let qt: String?
            public let qs: String?

            public init(
                lvl: String? = nil,
                hp: String? = nil,
                mhp: String? = nil,
                mn: String? = nil,
                mmn: String? = nil,
                mv: String? = nil,
                mmv: String? = nil,
                tnl: String? = nil,
                align: String? = nil,
                here: String? = nil,
                qt: String? = nil,
                qs: String? = nil
            ) {
                self.lvl = lvl
                self.hp = hp
                self.mhp = mhp
                self.mn = mn
                self.mmn = mmn
                self.mv = mv
                self.mmv = mmv
                self.tnl = tnl
                self.align = align
                self.here = here
                self.qt = qt
                self.qs = qs
            }

            /// Aardwolf's `group` GMCP sends these as **numbers** (`"hp": 85117`),
            /// but older fixtures used strings — decode either, normalised to
            /// `String?`, so live group data isn't silently dropped on a type
            /// mismatch (the bug that left the Group window empty).
            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: GroupMemberInfoKey.self)
                func value(_ key: GroupMemberInfoKey) -> String? {
                    if let number = try? container.decode(Int.self, forKey: key) { return String(number) }
                    if let string = try? container.decode(String.self, forKey: key) { return string }
                    return nil
                }
                lvl = value(.lvl)
                hp = value(.hp)
                mhp = value(.mhp)
                mn = value(.mn)
                mmn = value(.mmn)
                mv = value(.mv)
                mmv = value(.mmv)
                tnl = value(.tnl)
                align = value(.align)
                here = value(.here)
                qt = value(.qt)
                qs = value(.qs)
            }

            public var level: Int? {
                lvl.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }

            public var hpCurrent: Int? {
                hp.flatMap { Int($0) }
            }

            public var hpMax: Int? {
                mhp.flatMap { Int($0) }
            }

            /// True when the member is in the same room (`here == "1"`).
            public var isHere: Bool {
                here == "1"
            }

            /// The member is currently on a quest (`qs == "1"`).
            public var onQuest: Bool {
                qs == "1"
            }

            /// HP as a 0…1 fraction (full if unknown — so a member with no vitals
            /// sorts as healthy rather than "most hurt").
            public var hpFraction: Double {
                guard let current = hpCurrent, let maximum = hpMax, maximum > 0 else { return 1 }
                return Swift.max(0, Swift.min(1, Double(current) / Double(maximum)))
            }

            /// A compact quest tag for the panel: `[Q]` on a quest, else `Q:NN`
            /// from the timer, else `nil` (no quest info to show).
            public var questTag: String? {
                if onQuest { return "[Q]" }
                guard let qt = qt?.trimmingCharacters(in: .whitespaces),
                      let minutes = Int(qt), minutes > 0 else { return nil }
                return "Q:\(minutes)"
            }
        }

        public init(name: String, info: Info? = nil) {
            self.name = name
            self.info = info
        }
    }

    public init(
        groupname: String? = nil,
        leader: String? = nil,
        members: [Member]? = nil,
        reason: String? = nil
    ) {
        self.groupname = groupname
        self.leader = leader
        self.members = members
        self.reason = reason
    }
}
