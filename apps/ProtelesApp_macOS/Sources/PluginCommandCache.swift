import Foundation
import MudCore
import Observation

/// Caches the verb + subcommand grammar of the active profile's enabled plugins
/// for completion (#31). Built off-main by parsing each enabled plugin's XML
/// aliases (``PluginCommandIndex``) — independent of the session's deferred
/// in-game plugin load, so it's ready by the time you're typing. Throttled to
/// once per profile (the grammar is static for a session); the ghost reads the
/// in-memory index, never the disk.
@MainActor
@Observable
final class PluginCommandCache {
    @ObservationIgnored private(set) var index = PluginCommandIndex.empty
    @ObservationIgnored private var lastProfile: UUID?

    func refresh(forProfile id: UUID) {
        if id == lastProfile, !index.verbs.isEmpty { return }
        lastProfile = id
        Task.detached {
            var directories: [URL] = []
            if let url = try? PluginLibraryStore.defaultStoreURL() {
                let library = PluginLibraryStore(url: url)
                try? await library.load()
                directories = await library.enabled(forProfile: id).compactMap { try? $0.directory() }
            }
            let index = PluginCommandIndex.fromPluginDirectories(directories)
            await MainActor.run { self.index = index }
        }
    }
}
