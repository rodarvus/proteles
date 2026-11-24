import Foundation
@testable import MudCore

/// The Consider list's invariants over a replayed session, checked against
/// recognisers written here a second time (S0b item 2, #84): the checker must
/// not share code with the model it checks. It sees each snapshot the panel
/// would draw and the line that produced it.
///
/// Hard (a violation fails the corpus run):
/// - **No revival.** A row (by id) once dead never reads alive again; only a
///   new consider list, with new rows, starts over.
/// - **A dead mark has its kill line**, which names the mob.
/// - **A left mark has its departure line**: the mob's name, then a word,
///   then an exit (`A radiant ibis flutters south.`), or `<name> has fled!`.
/// - **No arrival row for a player**: a thunderclap entrance or a `(P)` name.
///
/// Soft (reported, for a person to read): departure-shaped lines naming a
/// listed mob that marked nothing.
struct ConsiderAudit {
    struct Counts {
        var snapshots = 0
        var deadMarks = 0
        /// Dead marks in a list of two or more mobs: the first live test's
        /// "kills come back" case.
        var deadInMultiMobLists = 0
        var leftMarks = 0
        var fledMarks = 0
        var arrivalRows = 0
        /// Departure verbs seen on left marks.
        var verbs: [String: Int] = [:]
        var missedDepartures = 0
        var thunderclaps = 0
    }

    private(set) var counts = Counts()
    private(set) var violations: [String] = []
    private(set) var missSamples: [String] = []
    private var dead: Set<Int> = []
    private var left: Set<Int> = []
    private var arrived: Set<Int> = []
    /// The rows the panel last showed.
    private(set) var lastMobs: [ConsiderMob] = []
    /// Names of the arrival rows the last snapshot added.
    private(set) var newArrivals: [String] = []

    static let exits: Set<String> = ["north", "south", "east", "west", "up", "down"]

    /// `text` without its leading `(flag)` groups.
    static func unflagged(_ text: String) -> Substring {
        var rest = Substring(text)
        while rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        return rest
    }

    /// The departure recogniser: `<name> <word> <exit>.` for this name.
    static func isDeparture(_ text: String, of name: String) -> (Bool, verb: String?) {
        let line = unflagged(text).lowercased()
        let prefix = name.lowercased() + " "
        guard line.hasPrefix(prefix), line.hasSuffix(".") else { return (false, nil) }
        let words = line.dropFirst(prefix.count).dropLast().split(separator: " ")
        guard words.count == 2, exits.contains(String(words[1])) else { return (false, nil) }
        return (true, String(words[0]))
    }

    static func isFlee(_ text: String, of name: String) -> Bool {
        unflagged(text).lowercased() == name.lowercased() + " has fled!"
    }

    /// The kill recogniser: the line names the mob, its first letter either
    /// case (`a wetland spite smoulders …`, `The voice of god has cleansed
    /// a wetland spite eternally! …`).
    static func isKill(_ text: String, of name: String) -> Bool {
        text.lowercased().contains(name.lowercased())
    }

    static func isPlayerArrival(_ text: String) -> Bool {
        text.hasPrefix("With a thunderclap, ") || text.hasPrefix("(P)") || text.hasPrefix("(Player)")
    }

    /// One snapshot, and the received line that produced it (nil for GMCP or
    /// a consider list).
    mutating func observe(_ mobs: [ConsiderMob], line: String?, at place: String) {
        counts.snapshots += 1
        newArrivals = []
        for mob in mobs {
            if dead.contains(mob.id), !mob.dead {
                violations.append("\(place) revived: \(mob.name) (row \(mob.id))")
                dead.remove(mob.id) // once per revival
            }
            if mob.dead, !dead.contains(mob.id) {
                dead.insert(mob.id)
                counts.deadMarks += 1
                if mobs.count >= 2 { counts.deadInMultiMobLists += 1 }
                if !(line.map { Self.isKill($0, of: mob.name) } ?? false) {
                    violations
                        .append("\(place) dead without its kill line: \(mob.name) — \(line ?? "(no line)")")
                }
            }
            if mob.left, !left.contains(mob.id) {
                left.insert(mob.id)
                checkLeft(mob, line: line, at: place)
            }
            if mob.came, !arrived.contains(mob.id) {
                arrived.insert(mob.id)
                counts.arrivalRows += 1
                newArrivals.append(mob.name)
                if let line, Self.isPlayerArrival(line) {
                    violations.append("\(place) a player's arrival made a row: \(line)")
                }
            }
        }
        lastMobs = mobs
    }

    private mutating func checkLeft(_ mob: ConsiderMob, line: String?, at place: String) {
        guard let line else {
            violations.append("\(place) left with no line: \(mob.name)")
            return
        }
        if mob.fled {
            counts.fledMarks += 1
            if !Self.isFlee(line, of: mob.name) {
                violations.append("\(place) fled without its line: \(mob.name) — \(line)")
            }
            return
        }
        counts.leftMarks += 1
        let (isDeparture, verb) = Self.isDeparture(line, of: mob.name)
        if isDeparture, let verb {
            counts.verbs[verb, default: 0] += 1
        } else {
            violations.append("\(place) left without its departure line: \(mob.name) — \(line)")
        }
    }

    /// A received line, once its snapshots (if any) are observed: a
    /// departure-shaped line naming a mob listed `before` it is a miss
    /// unless the list changed.
    mutating func noteLine(_ text: String, before: [ConsiderMob], at place: String) {
        if text.hasPrefix("With a thunderclap, ") { counts.thunderclaps += 1 }
        guard lastMobs == before, text.hasSuffix(".") else { return }
        let living = before.filter { !$0.dead && !$0.left }
        guard living.contains(where: { Self.isDeparture(text, of: $0.name).0 }) else { return }
        counts.missedDepartures += 1
        if missSamples.count < 40 { missSamples.append("\(place) \(text)") }
    }
}
