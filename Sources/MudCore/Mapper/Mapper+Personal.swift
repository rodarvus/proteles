import Foundation

/// Per-character overlay activation (D-111). The mapper opens the shared map
/// single-file at world load (before the character is known); once it is known,
/// the session calls ``attachPersonalStore(at:)`` to fold in that character's
/// `Aardwolf-personal.db`.
public extension Mapper {
    /// Re-open the store with the character's overlay attached, then reload the
    /// merged graph + republish the layout.
    ///
    /// **No-op unless the shared DB has been split** (the `personal_split`
    /// flag) — so we never read an un-migrated single-file DB through the
    /// overlay path, which would resurrect deleted rows ("State B"). Also a
    /// no-op if an overlay is already attached. A fresh character gets an empty
    /// overlay (created on open); its personal map fills in as it plays.
    func attachPersonalStore(at overlayURL: URL) throws {
        guard !store.hasPersonalStore else { return }
        guard (try? store.meta(forKey: MapperStore.personalSplitKey)) == "1" else { return }
        store = try MapperStore(url: store.url, personalURL: overlayURL)
        try reload()
    }

    /// Whether the live (single-file) map still needs the one-time personal-data
    /// migration — drives the migration prompt (D-111).
    func needsPersonalMigration() -> Bool {
        store.needsPersonalMigration()
    }

    /// Run the one-time migration (D-111): back up the shared map, split this
    /// character's personal data into `overlayURL`, then attach it — leaving the
    /// map whole but now per-character. Non-destructive (backup written first).
    func migratePersonal(overlayURL: URL, backupURL: URL) throws {
        try MapperStore.migratePersonal(
            sharedURL: store.url, overlayURL: overlayURL, backupURL: backupURL
        )
        try attachPersonalStore(at: overlayURL)
    }
}
