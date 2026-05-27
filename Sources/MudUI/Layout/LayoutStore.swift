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

    /// Panels shown as fixed top-right floating miniwindows over the game output
    /// (not in the dock tree). Persisted. The Text Map floats by default.
    public private(set) var floating: Set<PanelKind> = []

    /// Panels that float by default on a fresh install (the compact Text Map
    /// reads best as a top-right HUD rather than a dock tile).
    public static let defaultFloating: Set<PanelKind> = [.asciiMap]

    /// Where a drag-to-redock preview is currently shown — a *single* shared
    /// value rather than per-panel view state. Entering any target overwrites
    /// the previous one, so a highlight can never be orphaned if SwiftUI drops
    /// a `dropExited` callback (which used to leave it stuck on screen).
    public struct DropHighlight: Equatable, Sendable {
        public let target: PanelKind
        public let zone: DropZone
    }

    public private(set) var dropHighlight: DropHighlight?

    private let defaultsKey: String
    private let detachedKey: String
    private let floatingKey: String

    /// Load the persisted layout for `persistenceKey` (per world), or the
    /// shipped default. A corrupt/absent value falls back to `.standard`.
    public init(persistenceKey: String = "com.proteles.layout.default") {
        defaultsKey = persistenceKey
        detachedKey = persistenceKey + ".detached"
        floatingKey = persistenceKey + ".floating"
        let stored = UserDefaults.standard.data(forKey: persistenceKey)
            .flatMap { try? JSONDecoder().decode(PanelLayout.self, from: $0) }
        layout = stored?.renormalized() ?? .standard
        let storedDetached = UserDefaults.standard.array(forKey: detachedKey) as? [String] ?? []
        detached = Set(storedDetached.compactMap(PanelKind.init(rawValue:)))
        // First run with floating support → seed the defaults; else load.
        if let storedFloating = UserDefaults.standard.array(forKey: floatingKey) as? [String] {
            floating = Set(storedFloating.compactMap(PanelKind.init(rawValue:)))
        } else {
            floating = Self.defaultFloating
        }
        // A floating/detached panel must not also be in the dock tree.
        for kind in floating.union(detached) {
            layout = layout.removing(kind)
        }
    }

    /// Whether `kind` is currently shown — in the dock tree, a detached window,
    /// or a floating miniwindow (drives the Panels-menu checkmark).
    public func isVisible(_ kind: PanelKind) -> Bool {
        layout.contains(kind) || detached.contains(kind) || floating.contains(kind)
    }

    /// Whether `kind` is currently in its own window.
    public func isDetached(_ kind: PanelKind) -> Bool {
        detached.contains(kind)
    }

    /// Whether `kind` is currently a floating top-right miniwindow.
    public func isFloating(_ kind: PanelKind) -> Bool {
        floating.contains(kind)
    }

    /// Show/hide a panel (Panels menu). A detached panel hides by closing its
    /// window; a docked one is removed; a hidden one is re-inserted into the dock.
    public func toggle(_ kind: PanelKind) {
        if detached.contains(kind) {
            hideDetached(kind) // its window observes `isDetached` and dismisses
        } else if floating.contains(kind) {
            floating.remove(kind) // hide the miniwindow
            save()
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
        floating.remove(kind)
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

    // MARK: - Float / dock (top-right miniwindow)

    /// Lift `kind` out of the dock into a fixed top-right floating miniwindow.
    public func float(_ kind: PanelKind) {
        guard kind.isClosable, !floating.contains(kind) else { return }
        floating.insert(kind)
        detached.remove(kind)
        layout = layout.removing(kind)
        save()
    }

    /// Return a floating `kind` to the dock.
    public func dockFloating(_ kind: PanelKind) {
        guard floating.remove(kind) != nil else { return }
        if !layout.contains(kind) { layout = layout.inserting(kind) }
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
        floating = Self.defaultFloating
        for kind in floating {
            layout = layout.removing(kind)
        }
        save()
    }

    /// Re-dock `kind` at `zone` relative to `target` (drag-to-redock).
    public func move(_ kind: PanelKind, onto target: PanelKind, zone: DropZone) {
        let next = layout.moving(kind, onto: target, zone: zone)
        guard next != layout else { return }
        layout = next
        save()
    }

    // MARK: - Drag-to-redock highlight

    /// Show the drop preview for `target`/`zone` (a drag is hovering it).
    public func setDropHighlight(_ target: PanelKind, _ zone: DropZone) {
        let next = DropHighlight(target: target, zone: zone)
        if dropHighlight != next { dropHighlight = next }
    }

    /// Clear the drop preview. With a `target`, only clears if that target is
    /// the one currently highlighted (so a stale `dropExited` from a panel the
    /// drag already left can't wipe the panel it's now over).
    public func clearDropHighlight(forTarget target: PanelKind? = nil) {
        if let target, dropHighlight?.target != target { return }
        dropHighlight = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(detached.map(\.rawValue), forKey: detachedKey)
        UserDefaults.standard.set(floating.map(\.rawValue), forKey: floatingKey)
    }
}
