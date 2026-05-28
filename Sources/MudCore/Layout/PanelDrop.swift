import Foundation

/// Where a dragged panel is dropped relative to the panel it's dropped *onto*
/// (drag-to-redock — `docs/UI_REVAMP.md`). A drag-drop always picks an edge so
/// the dropped panel **splits/inserts** (never stacks). `.center` (tab-merge)
/// remains for programmatic use but is never produced by ``at(x:y:width:height:)``.
public enum DropZone: String, Sendable, CaseIterable {
    case leading, trailing, top, bottom, center

    /// Classify a drop point within a panel's bounds to its **nearest edge**, so
    /// a dropped panel splits/inserts on that side. Pure (takes plain numbers)
    /// so it's unit-testable without any UI geometry types.
    public static func at(x: Double, y: Double, width: Double, height: Double) -> DropZone {
        guard width > 0, height > 0 else { return .top }
        let nx = x / width, ny = y / height // normalized 0…1
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

    /// Insert an **absent** `kind` adjacent to `anchor` at `zone` (used to
    /// restore a re-shown panel to where it was hidden from). Falls back to the
    /// default right-rail insert if `kind` is already present or `anchor` is gone.
    func inserting(_ kind: PanelKind, near anchor: PanelKind, zone: DropZone) -> PanelLayout {
        guard !contains(kind), contains(anchor) else { return inserting(kind) }
        let combined = replacingNode(holding: anchor) { node in
            Self.combine(kind, with: node, zone: zone)
        }
        return combined.collapsed().renormalized()
    }

    /// Describe where `kind` currently sits as an adjacent panel + the side it
    /// occupies, so it can be restored there later. `nil` if `kind` is the only
    /// panel or isn't found.
    func anchorSlot(for kind: PanelKind) -> (anchor: PanelKind, zone: DropZone)? {
        guard case .split(let axis, let items) = self,
              let index = items.firstIndex(where: { $0.node.contains(kind) })
        else { return nil }
        // Descend to the innermost split holding `kind` first, so the anchor is
        // its closest neighbour (not a far-away ancestor sibling).
        if let deeper = items[index].node.anchorSlot(for: kind) { return deeper }
        // `kind` is a direct child here → anchor to an adjacent sibling. Prefer
        // the sibling *after* it (so it restores before that one); else before.
        let before: DropZone = axis == .vertical ? .top : .leading
        let after: DropZone = axis == .vertical ? .bottom : .trailing
        if index + 1 < items.count, let anchor = items[index + 1].node.firstLeaf {
            return (anchor, before)
        }
        if index - 1 >= 0, let anchor = items[index - 1].node.firstLeaf {
            return (anchor, after)
        }
        return nil
    }

    /// The first panel in depth-first order (a deterministic representative of
    /// a subtree, used as a re-dock anchor).
    var firstLeaf: PanelKind? {
        switch self {
        case .leaf(let kind): kind
        case .tabs(let panels, _): panels.first
        case .split(_, let items): items.lazy.compactMap(\.node.firstLeaf).first
        }
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
