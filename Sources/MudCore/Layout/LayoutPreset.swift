import Foundation

/// A named, saved panel arrangement the user can re-apply (UI revamp —
/// `docs/UI_REVAMP.md`). Captures the docked ``PanelLayout`` tree plus which
/// panels were floating; applying it restores that arrangement.
///
/// Detached (torn-out window) panels are intentionally *not* captured — a
/// preset describes the in-window layout, and applying one returns any detached
/// panels to the dock. Presets are value types so they're `Codable` and
/// unit-testable without the UI.
public struct LayoutPreset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var layout: PanelLayout
    /// Panels shown as floating top-right miniwindows in this arrangement.
    public var floating: [PanelKind]

    /// The preset's stable identity is its (unique) name.
    public var id: String {
        name
    }

    public init(name: String, layout: PanelLayout, floating: [PanelKind]) {
        self.name = name
        self.layout = layout
        self.floating = floating
    }
}

public extension [LayoutPreset] {
    /// Insert or replace `preset`, matching on a case-insensitive trimmed name,
    /// keeping the list sorted by name. A blank name is rejected (returns self).
    /// Pure so the save/overwrite rule is unit-testable.
    func upserting(_ preset: LayoutPreset) -> [LayoutPreset] {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return self }
        var next = filter { $0.name.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.append(LayoutPreset(name: trimmed, layout: preset.layout, floating: preset.floating))
        return next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Remove the preset with this (case-insensitive) name.
    func removing(named name: String) -> [LayoutPreset] {
        filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
    }
}
