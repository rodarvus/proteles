import CoreGraphics

/// Which corner of the container a floating miniwindow is anchored to. Offsets
/// are measured *inward* from that corner, so a window keeps its corner-relative
/// position when the main window resizes (UI revamp — the floating-miniwindow
/// rework, GH #33). CoreGraphics geometry only — no UI framework — so this stays
/// pure + unit-testable and portable to the eventual iPad layer.
public enum FloatingAnchor: String, Codable, Sendable, CaseIterable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    public var isTop: Bool {
        self == .topLeading || self == .topTrailing
    }

    public var isLeading: Bool {
        self == .topLeading || self == .bottomLeading
    }
}

/// Placement of one in-window floating miniwindow (architecture A — overlays
/// inside the main window, not separate NSWindows): an anchor corner, an inward
/// offset from that corner (the free-drag position), and an optional user-set
/// size. `size == nil` means **hug content** (economical — the window is only as
/// big as it needs to be); a non-nil size is the user's explicit resize.
public struct FloatingPlacement: Codable, Sendable, Equatable {
    public var anchor: FloatingAnchor
    /// Inward offset from `anchor` (non-negative in normal use).
    public var offset: CGSize
    /// Explicit size, or `nil` to hug content.
    public var size: CGSize?

    public init(
        anchor: FloatingAnchor = .topTrailing,
        offset: CGSize = CGSize(width: 12, height: 12),
        size: CGSize? = nil
    ) {
        self.anchor = anchor
        self.offset = offset
        self.size = size
    }
}

public extension FloatingPlacement {
    /// Resolve to a concrete rect inside `container`. Uses `content` when no
    /// explicit size is set, caps the size to the container, then positions from
    /// the anchor corner by `offset` and clamps so the window stays fully inside.
    func rect(in container: CGSize, content: CGSize) -> CGRect {
        let width = min(max(0, size?.width ?? content.width), container.width)
        let height = min(max(0, size?.height ?? content.height), container.height)

        let rawX = anchor.isLeading ? offset.width : container.width - width - offset.width
        let rawY = anchor.isTop ? offset.height : container.height - height - offset.height

        let x = min(max(0, rawX), max(0, container.width - width))
        let y = min(max(0, rawY), max(0, container.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Pure snapping: turn a freely-dragged rect into a tidy ``FloatingPlacement``
/// (anchor + inward offset). The window snaps flush against a nearby sibling
/// (stack below/above/left/right) if one is within range; otherwise it anchors
/// to the nearest container corner, flushing to a margin when dragged near an
/// edge. Position only — the caller keeps the existing `size`.
public enum FloatingSnap {
    /// - Parameters:
    ///   - rect: the dragged window's current rect (container coordinates).
    ///   - container: the main window's content size.
    ///   - siblings: rects of the other floating miniwindows (for stacking).
    ///   - margin: flush distance kept from a container edge when edge-snapping.
    ///   - threshold: how near (points) counts as "snap to this edge/sibling".
    ///   - gap: spacing left between two stacked siblings.
    /// - Returns: the snapped anchor + inward offset.
    public static func snap(
        rect: CGRect,
        in container: CGSize,
        siblings: [CGRect],
        margin: CGFloat = 10,
        threshold: CGFloat = 18,
        gap: CGFloat = 8
    ) -> (anchor: FloatingAnchor, offset: CGSize) {
        let aligned = siblingSnap(rect: rect, siblings: siblings, threshold: threshold, gap: gap) ?? rect

        // Anchor by which quadrant the window's centre sits in.
        let leading = aligned.midX < container.width / 2
        let top = aligned.midY < container.height / 2
        let anchor: FloatingAnchor = top
            ? (leading ? .topLeading : .topTrailing)
            : (leading ? .bottomLeading : .bottomTrailing)

        var ox = anchor.isLeading ? aligned.minX : container.width - aligned.maxX
        var oy = anchor.isTop ? aligned.minY : container.height - aligned.maxY
        if ox < threshold { ox = margin } // flush to the edge margin
        if oy < threshold { oy = margin }
        return (anchor, CGSize(width: max(0, ox), height: max(0, oy)))
    }

    /// If `rect` is within `threshold` of stacking flush against any sibling
    /// (with overlap on the perpendicular axis), return the aligned rect; else
    /// nil. Picks the closest qualifying edge across all siblings.
    private static func siblingSnap(
        rect: CGRect,
        siblings: [CGRect],
        threshold: CGFloat,
        gap: CGFloat
    ) -> CGRect? {
        var best: (distance: CGFloat, rect: CGRect)?
        func consider(_ candidate: CGRect, _ distance: CGFloat) {
            if distance < threshold, best == nil || distance < best!.distance {
                best = (distance, candidate)
            }
        }
        let size = rect.size
        for sibling in siblings {
            let xOverlap = rect.minX < sibling.maxX && rect.maxX > sibling.minX
            let yOverlap = rect.minY < sibling.maxY && rect.maxY > sibling.minY
            if xOverlap { // stack below / above — align x to the nearer L/R edge
                let alignedX = nearer(rect.minX, to: sibling.minX, or: sibling.maxX - size.width)
                consider(
                    CGRect(origin: CGPoint(x: alignedX, y: sibling.maxY + gap), size: size),
                    abs(rect.minY - (sibling.maxY + gap))
                )
                consider(
                    CGRect(origin: CGPoint(x: alignedX, y: sibling.minY - gap - size.height), size: size),
                    abs(rect.maxY - (sibling.minY - gap))
                )
            }
            if yOverlap { // stack right / left — align y to the nearer T/B edge
                let alignedY = nearer(rect.minY, to: sibling.minY, or: sibling.maxY - size.height)
                consider(
                    CGRect(origin: CGPoint(x: sibling.maxX + gap, y: alignedY), size: size),
                    abs(rect.minX - (sibling.maxX + gap))
                )
                consider(
                    CGRect(origin: CGPoint(x: sibling.minX - gap - size.width, y: alignedY), size: size),
                    abs(rect.maxX - (sibling.minX - gap))
                )
            }
        }
        return best?.rect
    }

    /// Whichever of the two candidates is closer to `value`.
    private static func nearer(_ value: CGFloat, to first: CGFloat, or second: CGFloat) -> CGFloat {
        abs(value - first) <= abs(value - second) ? first : second
    }
}
