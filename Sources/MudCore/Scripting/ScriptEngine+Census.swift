import Foundation

/// Per-plugin automation census (#63).
///
/// Motivated by the 2026-06-11 transient: one plugin loaded with its script
/// env alive (banners printed, sends worked) but its XML rules dead — aliases
/// leaked to the MUD, triggers never fired — and the transcript couldn't say
/// whether the rules were never registered or registered-but-disabled. The
/// session logs one census line per plugin load so the next occurrence is
/// diagnosable from the transcript alone. (Registration is also a `try?` —
/// `loadPlugin`'s `triggers.add` etc. drop a rule silently on failure; the
/// census is what makes that visible.)
public extension ScriptEngine {
    struct PluginRuleCensus: Sendable, Equatable {
        public let triggers: Int
        public let enabledTriggers: Int
        public let aliases: Int
        public let enabledAliases: Int
        public let timers: Int

        /// The transcript payload, e.g.
        /// `12 triggers (9 enabled), 4 aliases (4 enabled), 1 timer`.
        public var summary: String {
            "\(triggers) trigger\(triggers == 1 ? "" : "s") (\(enabledTriggers) enabled), "
                + "\(aliases) alias\(aliases == 1 ? "" : "es") (\(enabledAliases) enabled), "
                + "\(timers) timer\(timers == 1 ? "" : "s")"
        }
    }

    /// What the engines ACTUALLY hold for `pluginID` right now — XML-declared
    /// and dynamically-added rules alike (`automationOwners` tags both).
    func ruleCensus(forPlugin pluginID: String) -> PluginRuleCensus {
        let owned = Set(
            automationOwners.filter { $0.value == pluginID }.keys
        )
        let ownedTriggers = triggers.allTriggers.filter { owned.contains($0.id) }
        let ownedAliases = aliases.allAliases.filter { owned.contains($0.id) }
        let ownedTimers = timers.allTimers.filter { owned.contains($0.id) }
        return PluginRuleCensus(
            triggers: ownedTriggers.count,
            enabledTriggers: ownedTriggers.count(where: \.enabled),
            aliases: ownedAliases.count,
            enabledAliases: ownedAliases.count(where: \.enabled),
            timers: ownedTimers.count
        )
    }
}
