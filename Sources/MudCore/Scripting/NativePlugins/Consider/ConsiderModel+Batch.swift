import Foundation

/// The batch-attack (`conwall`) filter settings, ported with the plugin's
/// `Default_conwall_options` defaults. Mirrors which mobs a "kill everything
/// safe" sweep includes and how the AoE shortcut behaves.
public struct ConsiderBatchOptions: Sendable, Equatable, Codable {
    public var skipEvil = false
    public var skipGood = false
    public var skipNeutral = false
    public var skipSanctuary = false
    /// When set, `skipEvil`/`skipGood` are derived from the player's alignment
    /// each sweep (`UpdateSkipAutoAlign`): evil player skips good mobs, etc.
    public var skipAlignAuto = false
    /// Inclusive difficulty window a mob's whole range must sit within.
    public var minLevel = -2
    public var maxLevel = 20
    public var aoeCommand = "c ultrablast"
    public var minAoeCount = 5
    /// -1 disables the AoE shortcut (the plugin default).
    public var maxAoeCount = -1
    public var maxRoomCount = 5

    public init() {}
}

/// The result of planning a `conwall` sweep — the commands to send, or why none
/// were sent. The owning feature turns commands into `.send`/`.execute` effects.
public enum ConsiderBatchPlan: Sendable, Equatable {
    /// The list was empty (`"no targets to conwall"`).
    case noMobs
    /// Mobs exist but none survived the filter / count (`"No valid targets"`).
    case noValidTargets
    /// Fire the AoE command then the default command (the plugin's AoE branch).
    case aoe(commands: [String])
    /// Attack these formatted target commands, in send order.
    case targets([String])
}

public extension ConsiderModel {
    /// Apply alignment auto-skip from the player's `align` before a sweep
    /// (`UpdateSkipAutoAlign`). No-op unless `skipAlignAuto` is on.
    static func autoAlign(_ options: inout ConsiderBatchOptions, playerAlign: Int?) {
        guard options.skipAlignAuto, let align = playerAlign else { return }
        options.skipEvil = align < -500
        options.skipGood = align > 500
    }

    /// Whether a mob should be skipped by a sweep (`ShouldSkipMob`): already
    /// moved/attacked/dead, filtered by alignment/sanctuary, or its difficulty
    /// range falls outside `[minLevel, maxLevel]`.
    func shouldSkip(_ mob: ConsiderMob, options: ConsiderBatchOptions) -> Bool {
        if mob.left || mob.came || mob.attacked || mob.dead { return true }
        let flags = mob.rawFlags.lowercased()
        let isEvil = flags.contains("(r)") || flags.contains("(red aura)")
        let isGood = flags.contains("(g)") || flags.contains("(golden aura)")
        let isSanc = flags.contains("(w)") || flags.contains("(white aura)")
        if options.skipEvil, isEvil { return true }
        if options.skipGood, isGood { return true }
        if options.skipNeutral, !isEvil, !isGood { return true }
        if options.skipSanctuary, isSanc { return true }
        let bounds = ConsiderTier.parseRangeBounds(mob.rangeLabel)
        if bounds.lowerBound < options.minLevel || bounds.upperBound > options.maxLevel { return true }
        return false
    }

    /// Plan a `conwall` sweep with the current options (`Conw_all`): pick valid
    /// targets, choose the AoE shortcut or a reverse-order single-target run, and
    /// mark the chosen mobs attacked. Returns the commands to send.
    mutating func planBatch(
        options: ConsiderBatchOptions, defaultCommand: String, mode: ConsiderExecuteMode
    ) -> ConsiderBatchPlan {
        guard !mobs.isEmpty else { return .noMobs }

        let valid = mobs.indices.filter { !shouldSkip(mobs[$0], options: options) }
        let maxAoe = options.maxAoeCount
        let minAoe = options.minAoeCount
        let maxRoom = options.maxRoomCount

        // AoE shortcut: every mob is valid and the count sits in the AoE window.
        if maxAoe > 0, mobs.count == valid.count, valid.count >= minAoe, valid.count <= maxAoe {
            for i in mobs.indices {
                mobs[i].attacked = true
            }
            return .aoe(commands: [options.aoeCommand, defaultCommand])
        }

        var executeCount = min(valid.count, max(maxRoom, minAoe))
        // "Attack to AoE max, then AoE": when everything's valid but above the
        // AoE cap, only thin the herd down toward the cap.
        if maxAoe > 0, valid.count > maxAoe, mobs.count == valid.count {
            executeCount = min(valid.count - maxAoe, executeCount)
        }
        guard executeCount > 0 else { return .noValidTargets }

        // Attack the last `executeCount` valid targets in reverse, so killing an
        // earlier duplicate doesn't renumber a not-yet-engaged later one. Route
        // through `attackCommand` so each gets a proper attack sequence
        // (`Execute_Mob`), used later to disambiguate the kill victim.
        var commands: [String] = []
        for index in valid.suffix(executeCount).reversed() {
            if let command = attackCommand(position: index + 1, command: defaultCommand, mode: mode) {
                commands.append(command)
            }
        }
        return .targets(commands)
    }
}
