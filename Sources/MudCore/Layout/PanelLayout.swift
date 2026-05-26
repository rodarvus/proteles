import Foundation

/// Split orientation for a ``PanelLayout`` region.
public enum LayoutAxis: String, Codable, Sendable {
    /// Children laid out left→right (a row of columns).
    case horizontal
    /// Children laid out top→bottom (a column of rows).
    case vertical
}

/// A value-typed, `Codable` tree describing how panels tile the window — the
/// native equivalent of Mudlet's Geyser H/V-box nesting (see
/// `docs/UI_REVAMP.md`). Decoupled from SwiftUI so it's persistable per world
/// and fully unit-testable; the app maps each ``PanelKind`` leaf to a real view
/// at render time.
///
/// - `leaf` — a single panel.
/// - `tabs` — several panels stacked in one slot, one visible (the density
///   trick: e.g. S&D + Text Map share a slot).
/// - `split` — a resizable row/column of children, each taking a `fraction`
///   of the axis (fractions per split sum to 1).
public indirect enum PanelLayout: Codable, Equatable, Sendable {
    case leaf(PanelKind)
    case tabs(panels: [PanelKind], selection: Int)
    case split(axis: LayoutAxis, items: [Item])

    /// One child of a `split`: its share of the parent's main axis + its node.
    public struct Item: Codable, Equatable, Sendable {
        public var fraction: Double
        public var node: PanelLayout

        public init(fraction: Double, node: PanelLayout) {
            self.fraction = fraction
            self.node = node
        }
    }

    // MARK: - Presets

    /// The shipped default: big game output on the left; a right rail with the
    /// graphical Map on top, an S&D / Text-Map tab group in the middle, and
    /// Channels at the bottom — all four user-required panels visible at once.
    public static var standard: PanelLayout {
        .split(axis: .horizontal, items: [
            .init(fraction: 0.62, node: .leaf(.output)),
            .init(fraction: 0.38, node: .split(axis: .vertical, items: [
                .init(fraction: 0.45, node: .leaf(.map)),
                .init(fraction: 0.30, node: .tabs(panels: [.hunt, .asciiMap], selection: 0)),
                .init(fraction: 0.25, node: .leaf(.channels))
            ]))
        ])
    }

    /// Just the game output (panels all hidden) — the "focus" preset.
    public static var outputOnly: PanelLayout {
        .leaf(.output)
    }

    // MARK: - Queries

    /// Every panel present anywhere in the tree.
    public var allPanels: Set<PanelKind> {
        switch self {
        case .leaf(let kind): [kind]
        case .tabs(let panels, _): Set(panels)
        case .split(_, let items): items.reduce(into: Set()) { $0.formUnion($1.node.allPanels) }
        }
    }

    public func contains(_ kind: PanelKind) -> Bool {
        allPanels.contains(kind)
    }

    // MARK: - Mutations (pure; return a new normalized tree)

    /// Remove `kind` from the tree, collapsing any now-degenerate split/tab
    /// node. The main `output` panel is permanent, so removing it is a no-op.
    public func removing(_ kind: PanelKind) -> PanelLayout {
        guard kind.isClosable, contains(kind) else { return self }
        return (purged(kind) ?? .leaf(.output)).collapsed().renormalized()
    }

    /// Add `kind` (if absent) to the right rail — appended to the rightmost
    /// vertical column, or a new right column if there isn't one. A no-op if
    /// it's already shown.
    public func inserting(_ kind: PanelKind) -> PanelLayout {
        guard !contains(kind) else { return self }
        let inserted: PanelLayout = switch self {
        case .split(.horizontal, var items) where !items.isEmpty:
            insertingIntoRail(kind, items: &items)
        default:
            .split(axis: .horizontal, items: [
                .init(fraction: 0.7, node: self),
                .init(fraction: 0.3, node: .leaf(kind))
            ])
        }
        return inserted.collapsed().renormalized()
    }

    private func insertingIntoRail(_ kind: PanelKind, items: inout [Item]) -> PanelLayout {
        let last = items.count - 1
        if case .split(.vertical, let rail) = items[last].node {
            var rail = rail
            let share = 1.0 / Double(rail.count + 1)
            rail.append(.init(fraction: share, node: .leaf(kind)))
            items[last].node = .split(axis: .vertical, items: rail)
        } else {
            items.append(.init(fraction: 0.3, node: .leaf(kind)))
        }
        return .split(axis: .horizontal, items: items)
    }

    /// Toggle a panel: show it if hidden, hide it if shown.
    public func toggling(_ kind: PanelKind) -> PanelLayout {
        contains(kind) ? removing(kind) : inserting(kind)
    }

    /// Replace the `fraction`s of the split node addressed by `path` (a sequence
    /// of split-item indices from the root). Used by the divider drag-resize.
    public func settingFractions(_ fractions: [Double], at path: [Int]) -> PanelLayout {
        transformed(at: path) { node in
            guard case .split(let axis, var items) = node, items.count == fractions.count else { return }
            for index in items.indices {
                items[index].fraction = max(0, fractions[index])
            }
            node = .split(axis: axis, items: items)
        }
    }

    /// Set the selected tab of the `tabs` node addressed by `path`.
    public func settingTabSelection(_ selection: Int, at path: [Int]) -> PanelLayout {
        transformed(at: path) { node in
            guard case .tabs(let panels, _) = node, !panels.isEmpty else { return }
            node = .tabs(panels: panels, selection: min(max(0, selection), panels.count - 1))
        }
    }

    /// Apply `transform` to the node addressed by `path` (descending `split`
    /// children by index); returns a new tree.
    public func transformed(at path: [Int], _ transform: (inout PanelLayout) -> Void) -> PanelLayout {
        guard let first = path.first else {
            var copy = self
            transform(&copy)
            return copy
        }
        guard case .split(let axis, var items) = self, items.indices.contains(first) else { return self }
        items[first].node = items[first].node.transformed(at: Array(path.dropFirst()), transform)
        return .split(axis: axis, items: items)
    }

    // MARK: - Normalization

    /// Drop `kind`; returns nil when the whole node should disappear so its
    /// parent can drop it.
    private func purged(_ kind: PanelKind) -> PanelLayout? {
        switch self {
        case .leaf(let existing):
            return existing == kind ? nil : self
        case .tabs(let panels, let selection):
            var remaining = panels
            remaining.removeAll { $0 == kind }
            if remaining.isEmpty { return nil }
            if remaining.count == 1 { return .leaf(remaining[0]) }
            return .tabs(panels: remaining, selection: min(selection, remaining.count - 1))
        case .split(let axis, let items):
            let kept = items.compactMap { item -> Item? in
                item.node.purged(kind).map { Item(fraction: item.fraction, node: $0) }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0].node }
            return .split(axis: axis, items: kept)
        }
    }

    /// Flatten single-item splits and merge nested same-axis splits so the tree
    /// stays tidy (and divider math stays simple).
    public func collapsed() -> PanelLayout {
        guard case .split(let axis, let items) = self else { return self }
        var flattened: [Item] = []
        for item in items {
            let node = item.node.collapsed()
            if case .split(let innerAxis, let inner) = node, innerAxis == axis, !inner.isEmpty {
                let innerTotal = inner.reduce(0) { $0 + $1.fraction }
                for child in inner {
                    let share = innerTotal > 0 ? child.fraction / innerTotal : 1.0 / Double(inner.count)
                    flattened.append(.init(fraction: item.fraction * share, node: child.node))
                }
            } else {
                flattened.append(.init(fraction: item.fraction, node: node))
            }
        }
        return flattened.count == 1 ? flattened[0].node : .split(axis: axis, items: flattened)
    }

    /// Renormalize every split so its fractions sum to 1 (guards against drift
    /// from edits/resizes and de/serialization).
    public func renormalized() -> PanelLayout {
        guard case .split(let axis, let items) = self else { return self }
        let total = items.reduce(0) { $0 + max(0, $1.fraction) }
        let normalized = items.map { item in
            Item(
                fraction: total > 0 ? max(0, item.fraction) / total : 1.0 / Double(items.count),
                node: item.node.renormalized()
            )
        }
        return .split(axis: axis, items: normalized)
    }
}
