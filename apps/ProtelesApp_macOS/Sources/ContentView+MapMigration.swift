import MudCore
import SwiftUI

/// The one-time mapper-migration prompt (D-111), factored out of ``ContentView``
/// (its body is at the length budget) as a self-contained modifier that owns its
/// own presentation state and drives the migration directly. When the session
/// detects an un-migrated single-file map with personal data it emits the
/// logged-in character on `mapperMigrationPrompts`; this offers to split that
/// character's personals into a per-character overlay (a backup is taken first).
private struct MapMigrationPrompt: ViewModifier {
    let session: SessionController
    @State private var character: String?

    func body(content: Content) -> some View {
        content
            .task {
                for await name in session.mapperMigrationPrompts {
                    character = name
                }
            }
            .alert(
                "Upgrade map storage?",
                isPresented: Binding(
                    get: { character != nil },
                    set: { if !$0 { character = nil } }
                ),
                presenting: character
            ) { name in
                Button("Migrate now") {
                    Task { await session.migrateMapperPersonal(character: name) }
                    character = nil
                }
                Button("Later", role: .cancel) { character = nil }
            } message: { name in
                Text("""
                \(name)'s portals, custom exits, and notes will move to a \
                per-character map so they no longer mix with your other \
                characters. The shared world map stays shared. A backup is \
                saved first.
                """)
            }
    }
}

extension View {
    /// Present the one-time mapper-migration prompt for `session` (D-111).
    func mapMigrationPrompt(session: SessionController) -> some View {
        modifier(MapMigrationPrompt(session: session))
    }
}
