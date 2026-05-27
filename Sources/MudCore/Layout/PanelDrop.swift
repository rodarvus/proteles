import Foundation

/// Where a dragged panel is dropped relative to the panel it's dropped *onto*
/// (drag-to-redock — `docs/UI_REVAMP.md`). The four edges create a split; the
/// centre merges into a tab group.
public enum DropZone: String, Sendable, CaseIterable {
    case leading, trailing, top, bottom, center

    /// Classify a drop point within a panel's bounds: the central
    /// `centerFraction`×`centerFraction` box is `.center` (tab-merge);
    /// otherwise the nearest edge. Pure (takes plain numbers) so it's unit-
    /// testable without any UI geometry types.
    public static func at(
        x: Double, y: Double, width: Double, height: Double, centerFraction: Double = 0.34
    ) -> DropZone {
        guard width > 0, height > 0 else { return .center }
        let nx = x / width, ny = y / height // normalized 0…1
        let half = centerFraction / 2
        if abs(nx - 0.5) < half, abs(ny - 0.5) < half { return .center }
        let toLeft = nx, toRight = 1 - nx, toTop = ny, toBottom = 1 - ny
        let nearest = min(toLeft, toRight, toTop, toBottom)
        if nearest == toLeft { return .leading }
        if nearest == toRight { return .trailing }
        if nearest == toTop { return .top }
        return .bottom
    }

    /// The split axis an edge drop creates (centre has none).
    var axis: LayoutAxis? {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// Whether the moved panel goes *before* the target in the new split.
    var insertsBefore: Bool {
        self == .leading || self == .top
    }
}

public extension PanelLayout {
    /// Move `kind` so it docks at `zone` relative to `target` — the drag-to-
    /// redock operation. Edge zones wrap the target's slot in a new split (the
    /// moved panel taking half); `.center` merges the moved panel into the
    /// target's tab group (creating one from a lone leaf). No-op if either panel
    /// is absent, or they're the same panel and it isn't a tab-merge.
    ///
    /// Unlike ``removing(_:)`` this can move the permanent `output` panel too —
    /// it's re-inserted, so it never disappears.
    func moving(_ kind: PanelKind, onto target: PanelKind, zone: DropZone) -> PanelLayout {
        guard kind != target, contains(kind), contains(target) else { return self }
        // 1. Pull `kind` out of the tree (output included — it's re-placed below).
        guard let withoutKind = purged(kind)?.collapsed() else { return self }
        // 2. Replace the node holding `target` with the combined node.
        let combined = withoutKind.replacingNode(holding: target) { targetNode in
            Self.combine(kind, with: targetNode, zone: zone)
        }
        return combined.collapsed().renormalized()
    }

    /// Build the node that replaces the target's slot once `kind` docks at
    /// `zone`: a tab group (centre) or a 50/50 split (an edge).
    private static func combine(
        _ kind: PanelKind, with targetNode: PanelLayout, zone: DropZone
    ) -> PanelLayout {
        guard let axis = zone.axis else {
            // Centre: merge into (or form) a tab group, showing the dropped panel.
            switch targetNode {
            case .tabs(let panels, _):
                let merged = panels + [kind]
                return .tabs(panels: merged, selection: merged.count - 1)
            default:
                return .tabs(panels: targetNode.leadingPanels + [kind], selection: 1)
            }
        }
        let moved = PanelLayout.leaf(kind)
        let pair: [Item] = zone.insertsBefore
            ? [.init(fraction: 0.5, node: moved), .init(fraction: 0.5, node: targetNode)]
            : [.init(fraction: 0.5, node: targetNode), .init(fraction: 0.5, node: moved)]
        return .split(axis: axis, items: pair)
    }

    /// The panel(s) of a leaf/tabs node, for tab-merging an edge target.
    private var leadingPanels: [PanelKind] {
        switch self {
        case .leaf(let kind): [kind]
        case .tabs(let panels, _): panels
        case .split: [] // a split slot can't be tab-merged; combine wraps it instead
        }
    }

    /// Replace the leaf/tabs node that holds `kind` with `transform(node)`.
    /// `kind` is unique in the tree, so this hits exactly one node.
    private func replacingNode(
        holding kind: PanelKind, _ transform: (PanelLayout) -> PanelLayout
    ) -> PanelLayout {
        switch self {
        case .leaf(let existing):
            existing == kind ? transform(self) : self
        case .tabs(let panels, _):
            panels.contains(kind) ? transform(self) : self
        case .split(let axis, let items):
            .split(axis: axis, items: items.map {
                Item(fraction: $0.fraction, node: $0.node.replacingNode(holding: kind, transform))
            })
        }
    }
}
