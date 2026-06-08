import Foundation

/// The command grammar harvested from installed plugins' aliases (#31). Each
/// MUSHclient plugin registers its commands + subcommands as alias patterns, so
/// we extract their leading literal tokens (``TriggerPattern/commandTokens``) and
/// index them as `verb → subcommands` — recovering each plugin's command tree
/// (e.g. `dinv` → `build`/`put`/`refresh`/…, `ldb` → `level`/`help`/…) with no
/// per-plugin hardcoding. Feeds verb (word 0) + subcommand (word 1) completion.
public struct PluginCommandIndex: Sendable, Equatable {
    /// Every plugin command verb (the first token of each alias), sorted.
    public let verbs: [String]
    /// verb → its fixed subcommands (the second token), each list sorted.
    public let subcommands: [String: [String]]

    public static let empty = PluginCommandIndex(commandTokenLists: [])

    /// Build from each alias's command-token list (`[verb, subcommand, …]`).
    public init(commandTokenLists: [[String]]) {
        var verbSet: Set<String> = []
        var subs: [String: Set<String>] = [:]
        for tokens in commandTokenLists {
            guard let verb = tokens.first, !verb.isEmpty else { continue }
            verbSet.insert(verb)
            if tokens.count >= 2 { subs[verb, default: []].insert(tokens[1]) }
        }
        verbs = verbSet.sorted()
        subcommands = subs.mapValues { $0.sorted() }
    }

    /// Build from a set of plugin **directories** (each a self-contained plugin
    /// dir): parse every plugin's XML and harvest its aliases' command tokens.
    /// Unreadable/unparseable plugins are skipped. Pure I/O — safe off-main.
    public static func fromPluginDirectories(_ directories: [URL]) -> PluginCommandIndex {
        let lists: [[String]] = directories.flatMap { directory -> [[String]] in
            guard let xml = PluginInstaller.resolvePluginXML(at: directory),
                  let data = try? Data(contentsOf: xml),
                  let plugin = try? MUSHclientPluginLoader.parse(data)
            else { return [] }
            return plugin.aliases.map(\.pattern.commandTokens).filter { !$0.isEmpty }
        }
        return PluginCommandIndex(commandTokenLists: lists)
    }
}
