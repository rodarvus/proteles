import Foundation

/// The bundled Aardwolf command list (from `help commands`) — the canonical base
/// for first-word command completion (#31). The app unions this with the user's
/// aliases + loaded plugins' command words; this list is the ranked base.
public enum AardwolfCommands {
    /// Every Aardwolf command, lowercased + sorted. Loaded once from the
    /// resource bundle; empty only if the resource is somehow missing.
    public static let all: [String] = {
        guard let url = Bundle.module.url(forResource: "aardwolf-commands", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()
}

/// The bundled Aardwolf skill/spell list (from `allspells all`) — the candidate
/// source for `cast <spell>` argument completion (#32). The full game list (all
/// classes), so it may suggest a spell the character can't cast; that's the
/// accepted trade for a static, maintenance-free list.
public enum AardwolfSpells {
    /// Every skill/spell, lowercased + sorted. Loaded once from the bundle.
    public static let all: [String] = {
        guard let url = Bundle.module.url(forResource: "aardwolf-spells", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }()
}
