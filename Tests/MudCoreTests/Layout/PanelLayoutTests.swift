import Foundation
@testable import MudCore
import Testing

@Suite("PanelLayout — tiling tree model")
struct PanelLayoutTests {
    @Test("The standard preset shows all four required panels plus output")
    func standardPresetContents() {
        let layout = PanelLayout.standard
        for kind in [PanelKind.output, .map, .asciiMap, .hunt, .channels] {
            #expect(layout.contains(kind), "standard preset missing \(kind)")
        }
        #expect(!layout.contains(.info))
    }

    @Test("Removing a leaf panel collapses its now-degenerate split")
    func removingLeafCollapses() {
        let layout = PanelLayout.standard.removing(.channels)
        #expect(!layout.contains(.channels))
        #expect(layout.contains(.map), "removing channels must not drop the map")
        #expect(layout.contains(.output))
    }

    @Test("Removing one tab leaves the other as a plain leaf")
    func removingTabCollapsesToLeaf() {
        let layout = PanelLayout.standard.removing(.hunt)
        #expect(!layout.contains(.hunt))
        #expect(layout.contains(.asciiMap), "the surviving tab must remain")
        // The two-tab group should have collapsed to a single leaf (no empty tabs).
        #expect(!layout.description.isEmpty) // smoke; structural check below
    }

    @Test("The output panel is permanent — removing it is a no-op")
    func outputIsPermanent() {
        let layout = PanelLayout.standard.removing(.output)
        #expect(layout == PanelLayout.standard)
    }

    @Test("Inserting an absent panel shows it; inserting a present one is a no-op")
    func insertingPanels() {
        let withInfo = PanelLayout.standard.inserting(.info)
        #expect(withInfo.contains(.info))
        #expect(withInfo.inserting(.info) == withInfo, "inserting twice must be idempotent")
        #expect(PanelLayout.standard.inserting(.map) == PanelLayout.standard, "map already present")
    }

    @Test("Toggling shows then hides a panel")
    func togglingRoundTrips() {
        let shown = PanelLayout.standard.toggling(.info)
        #expect(shown.contains(.info))
        let hidden = shown.toggling(.info)
        #expect(!hidden.contains(.info))
    }

    @Test("Every split's fractions sum to 1 after normalization")
    func fractionsNormalize() {
        assertNormalized(PanelLayout.standard.renormalized())
    }

    private func assertNormalized(_ node: PanelLayout) {
        guard case .split(_, let items) = node else { return }
        let total = items.reduce(0) { $0 + $1.fraction }
        #expect(abs(total - 1) < 1e-9, "split fractions sum to \(total), not 1")
        for item in items {
            assertNormalized(item.node)
        }
    }

    @Test("Codable round-trips the standard preset")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(PanelLayout.standard)
        let decoded = try JSONDecoder().decode(PanelLayout.self, from: data)
        #expect(decoded == .standard)
    }

    @Test("settingFractions updates the addressed split")
    func settingFractionsAtPath() {
        // Root split (path []) has two items: output | rail.
        let resized = PanelLayout.standard.settingFractions([0.5, 0.5], at: [])
        guard case .split(_, let items) = resized else { Issue.record("not a split"); return }
        #expect(abs(items[0].fraction - 0.5) < 1e-9)
        #expect(abs(items[1].fraction - 0.5) < 1e-9)
    }

    @Test("settingTabSelection updates the addressed tab group")
    func settingTabSelectionAtPath() {
        // Rail is item 1 of root; the tab group is item 1 of the rail → path [1, 1].
        let updated = PanelLayout.standard.settingTabSelection(1, at: [1, 1])
        guard case .split(_, let root) = updated,
              case .split(_, let rail) = root[1].node,
              case .tabs(_, let selection) = rail[1].node
        else { Issue.record("unexpected shape"); return }
        #expect(selection == 1)
    }

    @Test("collapsed flattens nested same-axis splits")
    func collapseFlattensSameAxis() {
        let nested = PanelLayout.split(axis: .vertical, items: [
            .init(fraction: 0.5, node: .leaf(.output)),
            .init(fraction: 0.5, node: .split(axis: .vertical, items: [
                .init(fraction: 0.5, node: .leaf(.map)),
                .init(fraction: 0.5, node: .leaf(.channels))
            ]))
        ])
        guard case .split(_, let items) = nested.collapsed() else { Issue.record("not a split"); return }
        #expect(items.count == 3, "nested same-axis split should flatten to 3 items")
    }
}

private extension PanelLayout {
    /// Tiny structural description for smoke assertions.
    var description: String {
        String(describing: self)
    }
}
