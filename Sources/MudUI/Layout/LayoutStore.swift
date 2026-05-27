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

    /// Panels torn out into their own windows (not in the dock tree). Persisted
    /// so the app can re-open them on launch.
    public private(set) var detached: Set<PanelKind> = []

    private let defaultsKey: String
    private let detachedKey: String

    /// Load the persisted layout for `persistenceKey` (per world), or the
    /// shipped default. A corrupt/absent value falls back to `.standard`.
    public init(persistenceKey: String = "com.proteles.layout.default") {
        defaultsKey = persistenceKey
        detachedKey = persistenceKey + ".detached"
        let stored = UserDefaults.standard.data(forKey: persistenceKey)
            .flatMap { try? JSONDecoder().decode(PanelLayout.self, from: $0) }
        layout = stored?.renormalized() ?? .standard
        let storedDetached = UserDefaults.standard.array(forKey: detachedKey) as? [String] ?? []
        detached = Set(storedDetached.compactMap(PanelKind.init(rawValue:)))
    }

    /// Whether `kind` is currently shown — in the dock tree *or* a detached
    /// window (drives the Panels-menu checkmark).
    public func isVisible(_ kind: PanelKind) -> Bool {
        layout.contains(kind) || detached.contains(kind)
    }

    /// Whether `kind` is currently in its own window.
    public func isDetached(_ kind: PanelKind) -> Bool {
        detached.contains(kind)
    }

    /// Show/hide a panel (Panels menu). A detached panel hides by closing its
    /// window; a docked one is removed; a hidden one is re-inserted into the dock.
    public func toggle(_ kind: PanelKind) {
        if detached.contains(kind) {
            hideDetached(kind) // its window observes `isDetached` and dismisses
        } else {
            layout = layout.toggling(kind)
            save()
        }
    }

    /// Hide a docked panel (its ✕ button).
    public func close(_ kind: PanelKind) {
        layout = layout.removing(kind)
        save()
    }

    // MARK: - Detach / re-dock

    /// Tear `kind` out of the dock into its own window. The app opens the window
    /// in response to ``detached`` gaining the panel.
    public func detach(_ kind: PanelKind) {
        guard kind.isClosable, !detached.contains(kind) else { return }
        detached.insert(kind)
        layout = layout.removing(kind)
        save()
    }

    /// Return `kind` from its window to the dock (the window's re-dock button).
    public func redock(_ kind: PanelKind) {
        guard detached.contains(kind) else { return }
        detached.remove(kind)
        if !layout.contains(kind) { layout = layout.inserting(kind) }
        save()
    }

    /// Note a detached window closed (red ✕ or programmatic dismiss): drop it
    /// from ``detached`` without re-docking. No-op once already re-docked, so
    /// re-dock (which removes it first) then dismiss leaves the panel in the dock.
    public func hideDetached(_ kind: PanelKind) {
        guard detached.remove(kind) != nil else { return }
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

    /// Restore the shipped default arrangement ("Reset Layout" menu); any
    /// detached windows close (their panels return to the default dock).
    public func resetToDefault() {
        layout = .standard
        detached.removeAll()
        save()
    }

    /// Re-dock `kind` at `zone` relative to `target` (drag-to-redock).
    public func move(_ kind: PanelKind, onto target: PanelKind, zone: DropZone) {
        let next = layout.moving(kind, onto: target, zone: zone)
        guard next != layout else { return }
        layout = next
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(detached.map(\.rawValue), forKey: detachedKey)
    }
}
