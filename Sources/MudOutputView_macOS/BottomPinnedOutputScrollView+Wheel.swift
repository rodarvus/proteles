#if os(macOS)
    import AppKit

    @MainActor
    enum CoarseWheelNavigation {
        private static let maximumRowsPerEvent = 512

        static func rowDelta(for event: NSEvent) -> Int? {
            rowDelta(
                scrollingDeltaY: event.scrollingDeltaY,
                hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
            )
        }

        static func rowDelta(
            scrollingDeltaY: CGFloat,
            hasPreciseScrollingDeltas: Bool
        ) -> Int? {
            guard !hasPreciseScrollingDeltas,
                  scrollingDeltaY.isFinite,
                  scrollingDeltaY != 0
            else { return nil }

            let boundedMagnitude = min(abs(scrollingDeltaY), CGFloat(maximumRowsPerEvent))
            let rows = max(1, Int(boundedMagnitude.rounded()))
            return scrollingDeltaY > 0 ? rows : -rows
        }
    }

    extension BottomPinnedOutputScrollView {
        func isScrolledToBottom() -> Bool {
            guard let documentView else { return true }
            let visible = contentView.documentVisibleRect
            return Self.isScrolledToBottom(
                documentHeight: documentView.frame.height,
                visibleOriginY: visible.origin.y,
                visibleHeight: visible.height,
                threshold: autoScrollThreshold
            )
        }

        func isAtUserTail() -> Bool {
            guard let documentView else { return true }
            let visible = contentView.documentVisibleRect
            return Self.isScrolledToBottom(
                documentHeight: documentView.frame.height,
                visibleOriginY: visible.origin.y,
                visibleHeight: visible.height,
                threshold: 1
            )
        }

        nonisolated static func isScrolledToBottom(
            documentHeight: CGFloat,
            visibleOriginY: CGFloat,
            visibleHeight: CGFloat,
            threshold: CGFloat
        ) -> Bool {
            let distanceFromBottom = documentHeight - (visibleOriginY + visibleHeight)
            return distanceFromBottom < threshold
        }

        @discardableResult
        func scrollByVisualRows(_ signedRows: Int) -> Bool {
            guard signedRows != 0,
                  let textView = documentView as? NSTextView,
                  let targetY = TextViewportProbe.visualRowOrigin(
                      in: textView,
                      direction: signedRows > 0 ? .up : .down,
                      count: abs(signedRows)
                  )
            else { return false }

            invalidateReviewOriginPreservation()
            beginReviewing(reason: "wheel-row")
            let current = contentView.documentVisibleRect.origin
            contentView.scroll(to: CGPoint(x: current.x, y: targetY))
            reflectScrolledClipView(contentView)
            TextViewportProbe.layoutViewport(in: textView)

            if isAtUserTail() {
                followTailAndScrollToBottom(reason: "wheel-row-tail")
            } else {
                preserveReviewOrigin(contentView.bounds.origin)
            }
            return true
        }

        func emitWheelTransitionDiagnostic(
            _ diagnostic: WheelEventDiagnostic?,
            from previousMode: ScrollMode
        ) {
            guard previousMode != scrollMode, let diagnostic else { return }
            onWheelDiagnostic?(diagnostic.transcriptReason(
                afterOriginY: contentView.bounds.origin.y,
                transition: "\(previousMode.rawValue)-\(scrollMode.rawValue)"
            ))
        }
    }
#endif
