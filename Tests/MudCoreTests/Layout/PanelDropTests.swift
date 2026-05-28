import Foundation
@testable import MudCore
import Testing

@Suite("PanelLayout — drag-to-redock")
struct PanelDropTests {
    /// Count how many times `kind` appears across the whole tree (a move must
    /// relocate, never duplicate).
    private func occurrences(of kind: PanelKind, in layout: PanelLayout) -> Int {
        switch layout {
        case .leaf(let leaf): leaf == kind ? 1 : 0
        case .tabs(let panels, _): panels.count(where: { $0 == kind })
        case .split(_, let items): items.reduce(0) { $0 + occurrences(of: kind, in: $1.node) }
        }
    }

    // MARK: - Zone geometry

    @Test("DropZone.at always picks the nearest edge (never centre — drops split)")
    func zoneClassification() {
        #expect(DropZone.at(x: 5, y: 50, width: 100, height: 100) == .leading)
        #expect(DropZone.at(x: 95, y: 50, width: 100, height: 100) == .trailing)
        #expect(DropZone.at(x: 50, y: 5, width: 100, height: 100) == .top)
        #expect(DropZone.at(x: 50, y: 95, width: 100, height: 100) == .bottom)
        // A dead-centre point resolves to an edge, never .center.
        #expect(DropZone.at(x: 50, y: 50, width: 100, height: 100) != .center)
        // Degenerate bounds never crash.
        #expect(DropZone.at(x: 0, y: 0, width: 0, height: 0) != .center)
    }

    // MARK: - Moves

    @Test("An edge drop splits the target's slot and relocates (not duplicates) the panel")
    func edgeDropSplits() {
        // map is in the right rail; move it to the trailing edge of channels.
        let moved = PanelLayout.standard.moving(.map, onto: .channels, zone: .trailing)
        #expect(moved.contains(.map))
        #expect(moved.contains(.channels))
        #expect(occurrences(of: .map, in: moved) == 1, "map duplicated: \(moved)")
        // channels now sits in a horizontal split with map to its right.
        #expect(occurrences(of: .channels, in: moved) == 1)
    }

    @Test("A centre drop merges the panel into the target as a tab group")
    func centerDropMergesTabs() {
        // Move channels onto the map's centre → they share a tab slot.
        let moved = PanelLayout.standard.moving(.channels, onto: .map, zone: .center)
        #expect(occurrences(of: .channels, in: moved) == 1)
        #expect(occurrences(of: .map, in: moved) == 1)
        // A tabs node now holds both map and channels.
        #expect(hasTabGroup(containing: [.map, .channels], in: moved), "no map+channels tab group: \(moved)")
    }

    @Test("Dropping onto a panel already in a tab group extends that group")
    func centerDropExtendsExistingTabs() {
        // standard has a [hunt, asciiMap] tab group. Drop map into hunt's centre.
        let moved = PanelLayout.standard.moving(.map, onto: .hunt, zone: .center)
        #expect(
            hasTabGroup(containing: [.hunt, .asciiMap, .map], in: moved),
            "tab group not extended: \(moved)"
        )
        #expect(occurrences(of: .map, in: moved) == 1)
    }

    @Test("The permanent output panel can be moved (and is never lost)")
    func outputIsMovable() {
        let moved = PanelLayout.standard.moving(.output, onto: .channels, zone: .bottom)
        #expect(moved.contains(.output), "output must survive a move")
        #expect(occurrences(of: .output, in: moved) == 1)
        // Every other panel is still present.
        for kind in [PanelKind.map, .asciiMap, .hunt, .channels] {
            #expect(moved.contains(kind), "move dropped \(kind)")
        }
    }

    @Test("Moves that can't apply are no-ops")
    func noOps() {
        #expect(PanelLayout.standard.moving(.map, onto: .map, zone: .trailing) == .standard)
        #expect(PanelLayout.standard.moving(.info, onto: .map, zone: .top) == .standard) // info absent
    }

    @Test("Fractions stay normalized after a move")
    func normalizedAfterMove() {
        let moved = PanelLayout.standard.moving(.map, onto: .channels, zone: .top)
        assertNormalized(moved)
    }

    // MARK: - Re-show position memory

    @Test("anchorSlot describes a panel's neighbour + side; restore round-trips")
    func restoreSlotRoundTrips() {
        let layout = PanelLayout.standard
        // map is the top of the right rail, above the [hunt, asciiMap] tab group.
        guard let slot = layout.anchorSlot(for: .map) else {
            Issue.record("no anchor slot for map")
            return
        }
        #expect(slot.anchor == .hunt)
        #expect(slot.zone == .top)

        let hidden = layout.removing(.map)
        #expect(!hidden.contains(.map))

        let restored = hidden.inserting(.map, near: slot.anchor, zone: slot.zone)
        #expect(restored.contains(.map))
        #expect(occurrences(of: .map, in: restored) == 1)
        // Restoring puts map back in an equivalent slot (above hunt again).
        #expect(restored.anchorSlot(for: .map)?.anchor == .hunt)
        #expect(restored.anchorSlot(for: .map)?.zone == .top)
    }

    @Test("Restoring near a vanished anchor falls back to a default insert")
    func restoreFallback() {
        // Hide map and its whole anchor tab group, then try to restore near hunt.
        let layout = PanelLayout.standard
            .removing(.map)
            .removing(.hunt)
            .removing(.asciiMap)
        let restored = layout.inserting(.map, near: .hunt, zone: .top)
        #expect(restored.contains(.map)) // still inserted (fallback path)
        #expect(occurrences(of: .map, in: restored) == 1)
    }

    // MARK: - Helpers

    private func hasTabGroup(containing kinds: [PanelKind], in layout: PanelLayout) -> Bool {
        switch layout {
        case .leaf: false
        case .tabs(let panels, _): Set(kinds).isSubset(of: Set(panels))
        case .split(_, let items): items.contains { hasTabGroup(containing: kinds, in: $0.node) }
        }
    }

    private func assertNormalized(_ layout: PanelLayout) {
        guard case .split(_, let items) = layout else { return }
        let sum = items.reduce(0) { $0 + $1.fraction }
        #expect(abs(sum - 1) < 1e-9, "split fractions sum to \(sum): \(layout)")
        for item in items {
            assertNormalized(item.node)
        }
    }
}
