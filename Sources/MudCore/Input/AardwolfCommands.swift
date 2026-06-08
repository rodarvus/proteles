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
