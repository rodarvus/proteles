import MudCore
import SwiftUI

/// Command-line completion vocabulary assembly. Split out of `ContentView` to
/// keep that file within the size budget; the input view calls
/// ``makeCompletionVocabulary()`` on Tab / as-you-type.
extension ContentView {
    /// Build the current completion vocabulary: live GMCP nouns (group member
    /// names + room-name words) as context, recent output words, the verb set
    /// (bundled Aardwolf commands + the user's alias verbs), and the channel
    /// classification for kind-aware ghosting (#31). Called on Tab, so harvesting
    /// recent lines here is cheap.
    func makeCompletionVocabulary() -> CompletionVocabulary {
        var context: [String] = []
        // Player/people names — used both as context nouns and as the recipient
        // source for directed channels (`tell <who>`, #31).
        var players: [String] = []
        if let members = gmcp.state.group?.members { players += members.map(\.name) }
        context += players
        if let roomName = gmcp.state.room?.name {
            context += InputCompletion.harvestWords(from: [roomName], minLength: 3)
        }
        // Union the bundled list with the user's alias verbs + installed plugins'
        // command verbs (#31), deduped.
        let aliasVerbs = scripts.aliases.compactMap(\.pattern.leadingVerb)
        var seenVerb = Set<String>()
        let verbs = (Self.completionVerbs + aliasVerbs + pluginCommands.index.verbs)
            .filter { seenVerb.insert($0.lowercased()).inserted }
        return CompletionVocabulary(
            contextWords: context,
            recentWords: InputCompletion.harvestWords(from: recentLines.snapshot),
            verbs: verbs,
            playerWords: players,
            argumentSources: argumentSources(),
            broadcastChannels: CommandHistory.broadcastChannels,
            directedChannels: CommandHistory.directedChannels,
            pluginSubcommands: pluginCommands.index.subcommands
        )
    }

    /// Cached per-verb argument sources (#32). Exits are read live from GMCP
    /// (cheap); item/room/spell sources will be cached from the inventory DB /
    /// mapper / skills list as those pipelines land.
    private func argumentSources() -> [CommandArgumentKind: [String]] {
        var sources: [CommandArgumentKind: [String]] = [:]
        if let exits = gmcp.state.room?.exits, !exits.isEmpty {
            sources[.exit] = exits.keys.map { Self.directionNames[$0.lowercased()] ?? $0 }
        }
        sources[.spell] = AardwolfSpells.all // `cast <spell>` (#32)
        sources[.area] = snd.areaKeys // `runto`/`xrt <area>` (#32 A)
        sources[.item] = itemCompletions.keywords // `wear`/`wield`/… (#32 B)
        return sources
    }

    /// Cache S&D's area keys (off-main, one read) for `runto`/`xrt` completion
    /// (#32 A). No-op when S&D isn't installed; area data is world-wide + static,
    /// so this runs once at setup.
    func loadAreaCompletions() {
        guard snd.isInstalled else { return }
        let model = snd
        Task.detached {
            let keys = (try? SearchAndDestroyStore(
                url: SearchAndDestroyStore.defaultStoreURL()
            ).areaCompletions()) ?? []
            await MainActor.run { model.areaKeys = keys }
        }
    }

    /// Exit abbreviation → full direction name, so `open nor`→`north` (#32).
    private static let directionNames: [String: String] = [
        "n": "north", "s": "south", "e": "east", "w": "west", "u": "up", "d": "down",
        "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest"
    ]

    /// First-word completion verbs: the full bundled Aardwolf command list (#31)
    /// + channel names (so `gos`→`gossip`), deduped. The user's aliases + loaded
    /// plugins' command words union in via ``makeCompletionVocabulary()``.
    static let completionVerbs: [String] = {
        var seen = Set<String>()
        return (AardwolfCommands.all + Array(CommandHistory.communicationCommands))
            .filter { seen.insert($0.lowercased()).inserted }
    }()
}
