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
        // Remember `kind`'s current share so a same-axis reorder can keep its size
        // instead of being forced to half the target's slot.
        let priorFraction = fraction(of: kind)
        // 1. Pull `kind` out of the tree (output included — it's re-placed below).
        guard let withoutKind = purged(kind)?.collapsed() else { return self }
        // 2a. Reorder/insert: when `target` is a direct child of a split already on
        //     the drop's axis, slot `kind` in as an adjacent SIBLING rather than
        //     wrapping the target in a fresh 50/50 split. This keeps a drag within a
        //     row/column a true move — every panel just shrinks proportionally to
        //     make room, instead of the target halving and an untouched sibling
        //     ballooning to fill the renormalized remainder.
        let reordered = zone.axis.flatMap { axis in
            withoutKind.insertingSibling(
                kind,
                adjacentTo: target,
                axis: axis,
                before: zone.insertsBefore,
                fraction: priorFraction
            )
        }
        if let reordered {
            return reordered.collapsed().renormalized()
        }
        // 2b. Otherwise (cross-axis edge, or a `.center` tab-merge): replace the
        //     node holding `target` with the combined node (subdivide / tab group).
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

    /// Slot `kind` in as a sibling adjacent to `target` when `target` is a **direct
    /// child of a split already on `axis`** — the same-axis reorder/insert. Returns
    /// the rewritten tree, or `nil` when no such split exists (so the caller falls
    /// back to wrapping the target in a new split). `kind` takes `fraction` of the
    /// axis (its prior share, so a move preserves its size); `renormalized()` then
    /// shrinks the existing children proportionally to make room. `before` puts it
    /// on the leading/top side of `target`.
    private func insertingSibling(
        _ kind: PanelKind,
        adjacentTo target: PanelKind,
        axis: LayoutAxis,
        before: Bool,
        fraction: Double?
    ) -> PanelLayout? {
        guard case .split(let selfAxis, var items) = self else { return nil }
        let directIndex = items.firstIndex { $0.node.isLeafOrTabs(holding: target) }
        if selfAxis == axis, let index = directIndex {
            let share = fraction ?? (1.0 / Double(items.count + 1))
            items.insert(.init(fraction: share, node: .leaf(kind)), at: before ? index : index + 1)
            return .split(axis: selfAxis, items: items)
        }
        // No same-axis direct slot here — descend.
        for index in items.indices {
            if let rewritten = items[index].node.insertingSibling(
                kind, adjacentTo: target, axis: axis, before: before, fraction: fraction
            ) {
                items[index].node = rewritten
                return .split(axis: selfAxis, items: items)
            }
        }
        return nil
    }

    /// `kind`'s fraction within its immediate parent split (the share of the axis
    /// it occupies), or `nil` if it isn't found / is the whole tree.
    private func fraction(of kind: PanelKind) -> Double? {
        guard case .split(_, let items) = self else { return nil }
        for item in items {
            if item.node.isLeafOrTabs(holding: kind) { return item.fraction }
            if let deeper = item.node.fraction(of: kind) { return deeper }
        }
        return nil
    }

    /// True when this node is the leaf/tabs slot directly holding `kind` (the unit
    /// a same-axis sibling docks beside — docking onto a tabbed panel's edge places
    /// the new panel beside the whole tab group's slot).
    private func isLeafOrTabs(holding kind: PanelKind) -> Bool {
        switch self {
        case .leaf(let existing): existing == kind
        case .tabs(let panels, _): panels.contains(kind)
        case .split: false
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
