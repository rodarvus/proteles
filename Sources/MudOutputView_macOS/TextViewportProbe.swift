#if os(macOS)
    import AppKit
    import MudCore

    struct RenderedLineSpan {
        let id: LineID
        let utf16Length: Int
    }

    struct OutputViewportAnchor: Equatable {
        let lineID: LineID
        let utf16OffsetInLine: Int
        let viewportOffsetFromLineTop: CGFloat
    }

    struct TextViewportProbeMetrics {
        let viewportStartUTF16: Int?
        let viewportEndUTF16: Int?
        let topLayoutFragmentState: Int?
        let topVisualLineCount: Int?
    }

    @MainActor
    enum TextViewportProbe {
        static func metrics(for textView: NSTextView) -> TextViewportProbeMetrics {
            guard let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else {
                return TextViewportProbeMetrics(
                    viewportStartUTF16: nil,
                    viewportEndUTF16: nil,
                    topLayoutFragmentState: nil,
                    topVisualLineCount: nil
                )
            }

            let documentStart = contentManager.documentRange.location
            let viewportRange = layoutManager.textViewportLayoutController.viewportRange
            let viewportStart = viewportRange.map {
                contentManager.offset(from: documentStart, to: $0.location)
            }
            let viewportEnd = viewportRange.map {
                contentManager.offset(from: documentStart, to: $0.endLocation)
            }
            let fragment = topLayoutFragment(for: textView, layoutManager: layoutManager)
            return TextViewportProbeMetrics(
                viewportStartUTF16: viewportStart,
                viewportEndUTF16: viewportEnd,
                topLayoutFragmentState: fragment.map { Int($0.state.rawValue) },
                topVisualLineCount: fragment?.textLineFragments.count
            )
        }

        static func captureAnchor(
            in textView: NSTextView,
            renderedLines: [RenderedLineSpan]
        ) -> OutputViewportAnchor? {
            guard !renderedLines.isEmpty,
                  let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else { return nil }

            layoutManager.textViewportLayoutController.layoutViewport()
            guard let fragment = topLayoutFragment(for: textView, layoutManager: layoutManager)
            else { return nil }
            layoutManager.ensureLayout(for: fragment.rangeInElement)

            let visibleTop = scrollView.contentView.documentVisibleRect.minY
            let pointY = max(0, visibleTop - textView.textContainerOrigin.y + 0.5)
            guard let lineFragment = fragment.textLineFragment(
                forVerticalOffset: pointY - fragment.layoutFragmentFrame.minY,
                requiresExactMatch: false
            ) else { return nil }

            let documentStart = contentManager.documentRange.location
            let fragmentOffset = contentManager.offset(
                from: documentStart,
                to: fragment.rangeInElement.location
            )
            guard fragmentOffset != NSNotFound else { return nil }
            let characterOffset = fragmentOffset + lineFragment.characterRange.location
            guard let linePosition = renderedLine(at: characterOffset, in: renderedLines) else {
                return nil
            }
            let lineTop = textView.textContainerOrigin.y
                + fragment.layoutFragmentFrame.minY
                + lineFragment.typographicBounds.minY
            return OutputViewportAnchor(
                lineID: linePosition.line.id,
                utf16OffsetInLine: characterOffset - linePosition.startUTF16,
                viewportOffsetFromLineTop: visibleTop - lineTop
            )
        }

        @discardableResult
        static func restoreAnchor(
            _ anchor: OutputViewportAnchor,
            in textView: NSTextView,
            renderedLines: [RenderedLineSpan]
        ) -> Bool {
            guard !renderedLines.isEmpty,
                  let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.textLayoutManager,
                  let contentManager = layoutManager.textContentManager
            else { return false }

            let resolved = renderedLine(with: anchor.lineID, in: renderedLines)
                ?? (line: renderedLines[0], startUTF16: 0)
            let clampedOffset = min(
                max(0, anchor.utf16OffsetInLine),
                max(0, resolved.line.utf16Length - 1)
            )
            let characterOffset = resolved.startUTF16 + clampedOffset
            let documentStart = contentManager.documentRange.location
            guard let location = contentManager.location(
                documentStart,
                offsetBy: characterOffset
            ), let range = NSTextRange(location: location, end: location)
            else { return false }

            layoutManager.ensureLayout(for: range)
            guard let fragment = layoutManager.textLayoutFragment(for: location),
                  let lineFragment = fragment.textLineFragment(
                      for: location,
                      isUpstreamAffinity: false
                  )
            else { return false }

            let lineTop = textView.textContainerOrigin.y
                + fragment.layoutFragmentFrame.minY
                + lineFragment.typographicBounds.minY
            let maximumY = max(
                0,
                (scrollView.documentView?.frame.height ?? textView.frame.height)
                    - scrollView.contentView.bounds.height
            )
            let targetY = min(max(0, lineTop + anchor.viewportOffsetFromLineTop), maximumY)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            layoutManager.textViewportLayoutController.layoutViewport()
            return resolved.line.id == anchor.lineID
        }

        private static func topLayoutFragment(
            for textView: NSTextView,
            layoutManager: NSTextLayoutManager
        ) -> NSTextLayoutFragment? {
            let visible = textView.enclosingScrollView?.contentView.documentVisibleRect
                ?? textView.visibleRect
            let origin = textView.textContainerOrigin
            let point = CGPoint(
                x: max(0, visible.minX - origin.x + 1),
                y: max(0, visible.minY - origin.y + 0.5)
            )
            return layoutManager.textLayoutFragment(for: point)
                ?? layoutManager.textViewportLayoutController.viewportRange.flatMap {
                    layoutManager.textLayoutFragment(for: $0.location)
                }
        }

        private static func renderedLine(
            at characterOffset: Int,
            in lines: [RenderedLineSpan]
        ) -> (line: RenderedLineSpan, startUTF16: Int)? {
            var start = 0
            for line in lines {
                let end = start + line.utf16Length
                if characterOffset < end {
                    return (line, start)
                }
                start = end
            }
            guard let last = lines.last else { return nil }
            return (last, max(0, start - last.utf16Length))
        }

        private static func renderedLine(
            with id: LineID,
            in lines: [RenderedLineSpan]
        ) -> (line: RenderedLineSpan, startUTF16: Int)? {
            var start = 0
            for line in lines {
                if line.id == id { return (line, start) }
                start += line.utf16Length
            }
            return nil
        }
    }
#endif
