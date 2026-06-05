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

    /// Panels shown as **in-window floating miniwindows** over the game output
    /// (not in the dock tree), keyed to their per-panel ``FloatingPlacement``
    /// (anchor + offset + optional size). Persisted. The Text Map floats by
    /// default. (UI revamp — the floating-miniwindow rework, GH #33.)
    public private(set) var floating: [PanelKind: FloatingPlacement] = [:]

    /// Panels that float by default on a fresh install (the compact Text Map
    /// reads best as a top-right HUD rather than a dock tile).
    public static let defaultFloating: [PanelKind: FloatingPlacement] = [
        .asciiMap: FloatingPlacement(anchor: .topTrailing)
    ]

    /// Decode the persisted placement map (new format) from `data`, or nil.
    private static func decodeFloating(_ data: Data?) -> [PanelKind: FloatingPlacement]? {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: FloatingPlacement].self, from: data)
        else { return nil }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in
            PanelKind(rawValue: key).map { ($0, value) }
        })
    }

    /// A sensible starting placement when a panel is first floated: content-hug
    /// panels (Text Map, Commands) self-size; fill-style panels get an initial
    /// size so they don't collapse to nothing.
    static func defaultPlacement(for kind: PanelKind) -> FloatingPlacement {
        FloatingPlacement(
            anchor: .topTrailing,
            offset: CGSize(width: 12, height: 12),
            size: kind.floatingHugsContent ? nil : CGSize(width: 360, height: 300)
        )
    }

    /// Where a drag-to-redock preview is currently shown — a *single* shared
    /// value rather than per-panel view state. Entering any target overwrites
    /// the previous one, so a highlight can never be orphaned if SwiftUI drops
    /// a `dropExited` callback (which used to leave it stuck on screen).
    public struct DropHighlight: Equatable, Sendable {
        public let target: PanelKind
        public let zone: DropZone
    }

    public private(set) var dropHighlight: DropHighlight?

    /// Safety-net timer that clears a stuck drop preview (GH #37). SwiftUI can
    /// drop the final `dropExited` when a drag ends off every target, orphaning
    /// the highlight ("the blue box"). While a drag is live, dragging-updated
    /// events keep re-arming this; it only fires once the drag truly stops.
    private var highlightWatchdog: Timer?

    /// Where each hidden/detached panel last sat in the dock, so re-showing it
    /// restores its position instead of dumping it at the bottom. Session-scoped
    /// (the persisted `layout` already captures positions across launches).
    private struct AnchorSlot { let anchor: PanelKind; let zone: DropZone }
    private var lastSlot: [PanelKind: AnchorSlot] = [:]

    /// Saved, named arrangements the user can re-apply (shared across worlds).
    public private(set) var presets: [LayoutPreset] = []

    private let defaultsKey: String
    private let detachedKey: String
    private let floatingKey: String
    /// Presets are global (shared across worlds), so by default they use a
    /// fixed key independent of the per-world layout key.
    private let presetsKey: String

    /// Load the persisted layout for `persistenceKey` (per world), or the
    /// shipped default. A corrupt/absent value falls back to `.standard`.
    public init(
        persistenceKey: String = "com.proteles.layout.default",
        presetsKey: String = "com.proteles.layout.presets"
    ) {
        defaultsKey = persistenceKey
        detachedKey = persistenceKey + ".detached"
        floatingKey = persistenceKey + ".floating"
        self.presetsKey = presetsKey
        let stored = UserDefaults.standard.data(forKey: persistenceKey)
            .flatMap { try? JSONDecoder().decode(PanelLayout.self, from: $0) }
        layout = stored?.renormalized() ?? .standard
        let storedDetached = UserDefaults.standard.array(forKey: detachedKey) as? [String] ?? []
        detached = Set(storedDetached.compactMap(PanelKind.init(rawValue:)))
        // Load placements (new format), migrate the old set-of-kinds format, or
        // seed the defaults on first run.
        if let decoded = Self.decodeFloating(UserDefaults.standard.data(forKey: floatingKey)) {
            floating = decoded
        } else if let storedFloating = UserDefaults.standard.array(forKey: floatingKey) as? [String] {
            floating = Dictionary(uniqueKeysWithValues: storedFloating
                .compactMap(PanelKind.init(rawValue:))
                .map { ($0, Self.defaultPlacement(for: $0)) })
        } else {
            floating = Self.defaultFloating
        }
        // A floating/detached panel must not also be in the dock tree.
        for kind in Set(floating.keys).union(detached) {
            layout = layout.removing(kind)
        }
        presets = UserDefaults.standard.data(forKey: presetsKey)
            .flatMap { try? JSONDecoder().decode([LayoutPreset].self, from: $0) } ?? []
    }

    /// Whether `kind` is currently shown — in the dock tree, a detached window,
    /// or a floating miniwindow (drives the Panels-menu checkmark).
    public func isVisible(_ kind: PanelKind) -> Bool {
        layout.contains(kind) || detached.contains(kind) || floating[kind] != nil
    }

    /// Whether `kind` is currently in its own window.
    public func isDetached(_ kind: PanelKind) -> Bool {
        detached.contains(kind)
    }

    /// Whether `kind` is currently a floating top-right miniwindow.
    public func isFloating(_ kind: PanelKind) -> Bool {
        floating[kind] != nil
    }

    /// Show/hide a panel (Panels menu). A detached panel hides by closing its
    /// window; a docked one is removed; a hidden one is re-inserted into the dock.
    public func toggle(_ kind: PanelKind) {
        if detached.contains(kind) {
            hideDetached(kind) // its window observes `isDetached` and dismisses
        } else if floating[kind] != nil {
            floating[kind] = nil // hide the miniwindow
            save()
        } else if layout.contains(kind) {
            rememberSlot(kind)
            layout = layout.removing(kind)
            save()
        } else {
            layout = restoredInsert(kind)
            save()
        }
    }

    /// Hide a docked panel (its ✕ button).
    public func close(_ kind: PanelKind) {
        rememberSlot(kind)
        layout = layout.removing(kind)
        save()
    }

    /// Record where `kind` currently sits, so a later re-show restores it there.
    private func rememberSlot(_ kind: PanelKind) {
        if let slot = layout.anchorSlot(for: kind) {
            lastSlot[kind] = AnchorSlot(anchor: slot.anchor, zone: slot.zone)
        }
    }

    /// Re-insert `kind`, restoring its last slot when the anchor is still
    /// docked; otherwise the default right-rail insert.
    private func restoredInsert(_ kind: PanelKind) -> PanelLayout {
        if let slot = lastSlot[kind], layout.contains(slot.anchor) {
            return layout.inserting(kind, near: slot.anchor, zone: slot.zone)
        }
        return layout.inserting(kind)
    }

    // MARK: - Detach / re-dock

    /// Tear `kind` out of the dock into its own window. The app opens the window
    /// in response to ``detached`` gaining the panel.
    public func detach(_ kind: PanelKind) {
        guard kind.isClosable, !detached.contains(kind) else { return }
        rememberSlot(kind)
        detached.insert(kind)
        floating[kind] = nil
        layout = layout.removing(kind)
        save()
    }

    /// Return `kind` from its window to the dock (the window's re-dock button).
    public func redock(_ kind: PanelKind) {
        guard detached.contains(kind) else { return }
        detached.remove(kind)
        if !layout.contains(kind) { layout = restoredInsert(kind) }
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

    /// Lift `kind` out of the dock into an in-window floating miniwindow. Any
    /// closable panel can float now (GH #33); a starting `placement` may be
    /// supplied, else a sensible default (content-hug or an initial size).
    public func float(_ kind: PanelKind, at placement: FloatingPlacement? = nil) {
        guard kind.isClosable, floating[kind] == nil else { return }
        rememberSlot(kind)
        floating[kind] = placement ?? freshPlacement(for: kind)
        detached.remove(kind)
        layout = layout.removing(kind)
        save()
    }

    /// A starting placement for a newly-floated panel that avoids piling onto an
    /// occupied corner: pick the first corner no other floating panel anchors to
    /// (so a Float lands in free space — e.g. opposite the Text Map — rather than
    /// stacking on top of it). Falls back to top-right when all corners are used.
    private func freshPlacement(for kind: PanelKind) -> FloatingPlacement {
        let used = Set(floating.values.map(\.anchor))
        let preferred: [FloatingAnchor] = [.topTrailing, .topLeading, .bottomTrailing, .bottomLeading]
        let anchor = preferred.first { !used.contains($0) } ?? .topTrailing
        var placement = Self.defaultPlacement(for: kind)
        placement.anchor = anchor
        return placement
    }

    /// Update a floating panel's placement after a drag/snap or a resize.
    public func setFloatingPlacement(_ kind: PanelKind, _ placement: FloatingPlacement) {
        guard floating[kind] != nil else { return }
        floating[kind] = placement
        save()
    }

    /// Return a floating `kind` to the dock.
    public func dockFloating(_ kind: PanelKind) {
        guard floating.removeValue(forKey: kind) != nil else { return }
        if !layout.contains(kind) { layout = restoredInsert(kind) }
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
        for kind in floating.keys {
            layout = layout.removing(kind)
        }
        dropHighlight = nil // a drag preview can't survive a reset
        lastSlot.removeAll() // positions are meaningless after a reset
        save()
    }

    /// Re-dock `kind` at `zone` relative to `target` (drag-to-redock).
    public func move(_ kind: PanelKind, onto target: PanelKind, zone: DropZone) {
        let next = layout.moving(kind, onto: target, zone: zone)
        guard next != layout else { return }
        layout = next
        save()
    }

    // MARK: - Layout presets

    /// Save the current docked arrangement (+ which panels float) under `name`,
    /// overwriting any preset with the same name. Detached windows aren't part
    /// of a preset. A blank name is ignored.
    public func savePreset(named name: String) {
        let preset = LayoutPreset(name: name, layout: layout, floating: Array(floating.keys))
        presets = presets.upserting(preset)
        savePresets()
    }

    /// Apply a saved preset: restore its dock tree and floating panels, and
    /// return any detached panels to the dock (their windows close themselves).
    public func applyPreset(_ preset: LayoutPreset) {
        detached.removeAll() // detached windows observe this and dismiss
        floating = Dictionary(uniqueKeysWithValues: preset.floating.map {
            ($0, Self.defaultPlacement(for: $0))
        })
        layout = preset.layout.renormalized()
        for kind in floating.keys {
            layout = layout.removing(kind)
        }
        save()
    }

    /// Delete the named preset.
    public func deletePreset(named name: String) {
        presets = presets.removing(named: name)
        savePresets()
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: presetsKey)
        }
    }

    // MARK: - Drag-to-redock highlight

    /// Show the drop preview for `target`/`zone` (a drag is hovering it).
    public func setDropHighlight(_ target: PanelKind, _ zone: DropZone) {
        let next = DropHighlight(target: target, zone: zone)
        if dropHighlight != next { dropHighlight = next }
        armHighlightWatchdog()
    }

    /// Clear the drop preview. With a `target`, only clears if that target is
    /// the one currently highlighted (so a stale `dropExited` from a panel the
    /// drag already left can't wipe the panel it's now over).
    public func clearDropHighlight(forTarget target: PanelKind? = nil) {
        if let target, dropHighlight?.target != target { return }
        highlightWatchdog?.invalidate()
        highlightWatchdog = nil
        dropHighlight = nil
    }

    /// (Re)arm the safety-net timer. Each drag-update call pushes it out, so it
    /// fires only after dragging-updated events stop (the drag ended without a
    /// clearing `dropExited`/`performDrop`), clearing any stuck preview. Worst
    /// case — if SwiftUI sent no periodic updates during a long stationary hover
    /// — the preview hides after the interval; the drop itself is unaffected.
    private func armHighlightWatchdog() {
        highlightWatchdog?.invalidate()
        highlightWatchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearDropHighlight() }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(layout) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(detached.map(\.rawValue), forKey: detachedKey)
        let placements = Dictionary(uniqueKeysWithValues: floating.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(placements) {
            UserDefaults.standard.set(data, forKey: floatingKey)
        }
    }
}
