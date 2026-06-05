import CoreGraphics
@testable import MudCore
import Testing

@Suite("FloatingPlacement — resolve + snap (#33)")
struct FloatingPlacementTests {
    private let container = CGSize(width: 1000, height: 800)

    // MARK: - rect(in:content:)

    @Test("Top-trailing anchors to the right edge by the inward offset")
    func topTrailingRect() {
        let placement = FloatingPlacement(anchor: .topTrailing, offset: CGSize(width: 12, height: 12))
        let resolved = placement.rect(in: container, content: CGSize(width: 200, height: 100))
        #expect(resolved == CGRect(x: 1000 - 200 - 12, y: 12, width: 200, height: 100))
    }

    @Test("Bottom-leading anchors to the bottom-left corner")
    func bottomLeadingRect() {
        let placement = FloatingPlacement(anchor: .bottomLeading, offset: CGSize(width: 10, height: 10))
        let resolved = placement.rect(in: container, content: CGSize(width: 100, height: 100))
        #expect(resolved == CGRect(x: 10, y: 800 - 100 - 10, width: 100, height: 100))
    }

    @Test("An explicit size overrides the content size")
    func explicitSize() {
        let placement = FloatingPlacement(
            anchor: .topLeading,
            offset: .zero,
            size: CGSize(width: 300, height: 250)
        )
        let resolved = placement.rect(in: container, content: CGSize(width: 50, height: 50))
        #expect(resolved.size == CGSize(width: 300, height: 250))
    }

    @Test("Oversized content is capped to the container and clamped on-screen")
    func clampsToContainer() {
        let placement = FloatingPlacement(anchor: .topTrailing, offset: CGSize(width: 50, height: 50))
        let resolved = placement.rect(in: container, content: CGSize(width: 5000, height: 5000))
        #expect(resolved.width == container.width)
        #expect(resolved.height == container.height)
        #expect(resolved.minX == 0)
        #expect(resolved.minY == 0)
    }

    // MARK: - snap

    @Test("Free position anchors to the nearest corner by quadrant")
    func snapQuadrantAnchor() {
        // Centre in the bottom-right quadrant, clear of edges + siblings.
        let dragged = CGRect(x: 700, y: 600, width: 150, height: 100) // centre (775, 650)
        let result = FloatingSnap.snap(rect: dragged, in: container, siblings: [])
        #expect(result.anchor == .bottomTrailing)
        #expect(result.offset.width == container.width - dragged.maxX)
        #expect(result.offset.height == container.height - dragged.maxY)
    }

    @Test("Near an edge, snaps flush to the margin")
    func snapEdgeMargin() {
        let dragged = CGRect(x: 3, y: 4, width: 120, height: 90) // hugging top-left
        let result = FloatingSnap.snap(rect: dragged, in: container, siblings: [], margin: 10, threshold: 18)
        #expect(result.anchor == .topLeading)
        #expect(result.offset == CGSize(width: 10, height: 10))
    }

    @Test("Stacks flush below a sibling when dropped just under it")
    func snapStackBelowSibling() {
        let sibling = CGRect(x: 100, y: 100, width: 200, height: 100) // maxY 200
        let dragged = CGRect(x: 110, y: 205, width: 200, height: 80) // just below, x-overlapping
        let result = FloatingSnap.snap(
            rect: dragged,
            in: container,
            siblings: [sibling],
            margin: 10,
            threshold: 18,
            gap: 8
        )
        // Aligned rect becomes (100, 208, 200, 80): centre (200, 248) → top-leading.
        #expect(result.anchor == .topLeading)
        #expect(result.offset == CGSize(width: 100, height: 208))
    }

    @Test("Stacking below aligns to the nearer edge (right, not always left)")
    func snapStackBelowAlignsNearerEdge() {
        let sibling = CGRect(x: 100, y: 100, width: 300, height: 100) // right edge 400
        // A narrow window dropped just below + near the sibling's RIGHT edge.
        let dragged = CGRect(x: 290, y: 205, width: 100, height: 80)
        let result = FloatingSnap.snap(
            rect: dragged,
            in: container,
            siblings: [sibling],
            margin: 10,
            threshold: 18,
            gap: 8
        )
        // Right-aligned: x = 400 - 100 = 300 (not 100). topLeading → offset.x == 300.
        #expect(result.offset.width == 300)
    }
}
