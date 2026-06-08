import Foundation
import MudCore
import Observation

/// Caches dinv item keywords for `wear`/`wield`/`quaff`/… argument completion
/// (#32 B). The *only* completion-side reader of dinv.db, deliberately isolated:
/// one off-main query, refreshed on connect and skipped when the DB is unchanged
/// — never touched on a keystroke (the ghost reads ``keywords`` in memory).
@MainActor
@Observable
final class ItemCompletionCache {
    @ObservationIgnored private(set) var keywords: [String] = []
    @ObservationIgnored private var lastCharacter: String?
    @ObservationIgnored private var lastModified: Date?

    /// Refresh from `Databases/<character>/dinv.db`, off the main thread. A no-op
    /// when dinv.db is unchanged since the last read for this character, so it's
    /// safe to call on every connect.
    func refresh(character: String) {
        guard !character.isEmpty,
              let url = try? ProtelesPaths.pluginDatabaseURL(character: character, fileName: "dinv.db")
        else { return }
        let modified = (try? FileManager.default
            .attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if character == lastCharacter, modified == lastModified, !keywords.isEmpty { return }
        lastCharacter = character
        lastModified = modified
        Task.detached {
            let words = (try? DinvItemReader.itemKeywords(at: url)) ?? []
            await MainActor.run { self.keywords = words }
        }
    }
}
