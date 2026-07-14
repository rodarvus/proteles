#if os(macOS)
    import AppKit

    extension TextViewportProbe {
        enum VisualPageDirection {
            case up
            case down
        }

        /// Return the document origin for a page step that retains one fully
        /// visible visual row. Wrapped rows count independently.
        static func visualPageOrigin(
            in textView: NSTextView,
            direction: VisualPageDirection
        ) -> CGFloat? {
            guard let layoutManager = textView.textLayoutManager else { return nil }
            layoutManager.textViewportLayoutController.layoutViewport()
            let lines = fullyVisibleVisualLines(in: textView, layoutManager: layoutManager)
            guard let first = lines.first, let last = lines.last else { return nil }
            let visible = textView.enclosingScrollView?.contentView.documentVisibleRect
                ?? textView.visibleRect
            let pageStep = lines.count > 1
                ? last.lowerBound - first.lowerBound
                : max(1, visible.height - (first.upperBound - first.lowerBound))

            switch direction {
            case .down:
                return lines.count > 1 ? last.lowerBound : visible.minY + pageStep
            case .up:
                return max(textView.frame.minY, first.lowerBound - pageStep)
            }
        }

        private static func fullyVisibleVisualLines(
            in textView: NSTextView,
            layoutManager: NSTextLayoutManager
        ) -> [ClosedRange<CGFloat>] {
            let visible = textView.enclosingScrollView?.contentView.documentVisibleRect
                ?? textView.visibleRect
            guard visible.height > 0, textView.frame.height > 0 else { return [] }

            let tolerance: CGFloat = 0.5
            var probeY = min(
                max(visible.minY + tolerance, textView.frame.minY + tolerance),
                textView.frame.maxY - tolerance
            )
            var result: [ClosedRange<CGFloat>] = []

            for _ in 0..<512 {
                guard let line = visualLine(
                    at: probeY,
                    in: textView,
                    layoutManager: layoutManager
                ) else { break }
                if line.upperBound > visible.maxY + tolerance { break }
                if line.lowerBound >= visible.minY - tolerance {
                    result.append(line)
                }

                let nextProbeY = line.upperBound + tolerance
                guard nextProbeY > probeY,
                      nextProbeY < textView.frame.maxY
                else { break }
                probeY = nextProbeY
            }
            return result
        }
    }
#endif
