import MudCore
import Observation
import SwiftUI

/// Owns the live ``PanelLayout`` for the main window and persists it (the UI
/// revamp — `docs/UI_REVAMP.md`). The tree itself is a pure value type in
/// MudCore; this is the `@Observable` reference SwiftUI binds to, plus the
/// mutation + persistence glue. Replaces the old single-panel `LayoutModel`.
@MainActor
@Observable
public final class LayoutStore {
    /// The current tiling tree. Mutating it re-renders the window.
    public var layout: PanelLayout

    private let defaultsKey: String

    /// Load the persisted layout for `persistenceKey` (per world), or the
    /// shipped default. A corrupt/absent value falls back to `.standard`.
    public init(persistenceKey: String = "com.proteles.layout.default") {
        defaultsKey = persistenceKey
        let stored = UserDefaults.standard.data(forKey: persistenceKey)
            .flatMap { try? JSONDecoder().decode(PanelLayout.self, from: $0) }
        layout = stored?.renormalized() ?? .standard
    }

    /// Whether `kind` is currently shown anywhere in the tree.
    public func isVisible(_ kind: PanelKind) -> Bool {
        layout.contains(kind)
    }

    /// Show/hide a panel (Panels menu, panel ✕ button).
    public func toggle(_ kind: PanelKind) {
        layout = layout.toggling(kind)
        save()
    }

    /// Hide a panel (its close button).
    public func close(_ kind: PanelKind) {
        layout = layout.removing(kind)
        save()
    }

    /// Persist new divider fractions for the split at `path` (divider drag).
    public func setFractions(_ fractions: [Double], at path: [Int]) {
        layout = layout.settingFractions(fractions, at: path)
        save()
    }

    /// Persist the selected tab for the tab group at `path`.
    public func selectTab(_ index: Int, at path: [Int]) {
        layout = layout.settingTabSelection(index, at: path)
        save()
    }

    /// Restore the shipped default arrangement ("Reset Layout" menu).
    public func resetToDefault() {
        layout = .standard
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
