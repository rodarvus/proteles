#if os(macOS)
    import AppKit
    import MudCore

    struct TailReconciliationState {
        static let maximumChecks = 4

        var generation = 0
        var check = 0
        var isScheduled = false
        var startedAt: ContinuousClock.Instant?
        var diagnosticStarted = false
        var source = "none"
        var workMilliseconds: [Int] = []
        var expectedUserInteractionGeneration: Int?

        mutating func begin(
            source: String,
            userInteractionGeneration: Int?,
            preservingSchedule: Bool
        ) {
            generation += 1
            check = 0
            isScheduled = preservingSchedule
            startedAt = ContinuousClock.now
            diagnosticStarted = false
            self.source = source
            workMilliseconds.removeAll(keepingCapacity: true)
            expectedUserInteractionGeneration = userInteractionGeneration
        }

        mutating func finish() {
            check = 0
            isScheduled = false
            startedAt = nil
            diagnosticStarted = false
            source = "none"
            workMilliseconds.removeAll(keepingCapacity: true)
            expectedUserInteractionGeneration = nil
        }
    }

    extension RenderCoordinator {
        func currentViewportAnchor() -> OutputViewportAnchor? {
            guard let textView else { return nil }
            return currentViewportAnchor(in: textView)
        }

        var currentScrollMode: BottomPinnedOutputScrollView.ScrollMode {
            guard let scrollView = textView?.enclosingScrollView as? BottomPinnedOutputScrollView
            else { return .followingTail }
            return scrollView.scrollMode
        }

        func configureInitialScrollMode() {
            guard let scrollView = textView?.enclosingScrollView as? BottomPinnedOutputScrollView
            else { return }
            let mode: BottomPinnedOutputScrollView.ScrollMode = initialScrollPosition == .bottom
                ? .followingTail
                : .reviewing
            scrollView.setInitialScrollMode(mode)
        }

        /// Scroll immediately, then coalesce follow-up confirmation onto the
        /// main queue. The expected first TextKit settle pass is silent. Only
        /// a miss that survives that pass starts diagnostics and bounded
        /// corrective layout/scroll passes.
        func requestTailReconciliation(in textView: NSTextView, source: String) {
            let wasScheduled = tailReconciliation.isScheduled
            if tailReconciliation.diagnosticStarted {
                emitTailReconciliationOutcome("cancelled-superseded")
            }
            let scrollView = textView.enclosingScrollView as? BottomPinnedOutputScrollView
            tailReconciliation.begin(
                source: source,
                userInteractionGeneration: scrollView?.userInteractionGeneration,
                preservingSchedule: wasScheduled
            )
            performTailScroll(in: textView, forcesViewportLayout: false)
            scheduleTailReconciliationIfNeeded()
        }

        func cancelTailReconciliation(reason: String) {
            guard tailReconciliation.startedAt != nil else { return }
            if tailReconciliation.diagnosticStarted {
                emitTailReconciliationOutcome("cancelled-\(reason)")
            }
            tailReconciliation.generation += 1
            tailReconciliation.finish()
        }

        private func scheduleTailReconciliationIfNeeded(afterLayoutTurn: Bool = false) {
            guard !tailReconciliation.isScheduled,
                  tailReconciliation.startedAt != nil
            else { return }
            tailReconciliation.isScheduled = true
            if afterLayoutTurn {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) {
                    [weak self] in
                    self?.runTailReconciliation()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.runTailReconciliation()
                }
            }
        }

        private func runTailReconciliation() {
            guard tailReconciliation.isScheduled else { return }
            tailReconciliation.isScheduled = false
            guard tailReconciliation.startedAt != nil,
                  let textView,
                  isFollowingTail(textView)
            else {
                finishCancelledTailReconciliation(reason: "review")
                return
            }
            if userIntervenedDuringTailReconciliation(in: textView) {
                finishCancelledTailReconciliation(reason: "user-intent")
                return
            }

            tailReconciliation.check += 1
            if viewportReachesTail(in: textView) {
                if tailReconciliation.diagnosticStarted {
                    emitTailReconciliationOutcome("converged")
                }
                tailReconciliation.finish()
                return
            }

            if tailReconciliation.check >= 2, !tailReconciliation.diagnosticStarted {
                tailReconciliation.diagnosticStarted = true
                emitHealth(reason: tailReconciliationReason(outcome: "miss"))
            }
            guard tailReconciliation.check < TailReconciliationState.maximumChecks else {
                emitTailReconciliationOutcome("exhausted")
                tailReconciliation.finish()
                return
            }

            performTailScroll(in: textView, forcesViewportLayout: true)
            scheduleTailReconciliationIfNeeded(afterLayoutTurn: tailReconciliation.check >= 2)
        }

        private func finishCancelledTailReconciliation(reason: String) {
            if tailReconciliation.diagnosticStarted {
                emitTailReconciliationOutcome("cancelled-\(reason)")
            }
            tailReconciliation.finish()
        }

        private func viewportReachesTail(in textView: NSTextView) -> Bool {
            guard geometryReachesTail(in: textView) else { return false }
            return TextViewportProbe.viewportEndsAtStorageEnd(in: textView) ?? true
        }

        private func geometryReachesTail(in textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView else { return true }
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let visible = scrollView.contentView.documentVisibleRect
            let distanceFromBottom = documentHeight - visible.maxY
            return distanceFromBottom <= 1
        }

        private func userIntervenedDuringTailReconciliation(in textView: NSTextView) -> Bool {
            guard let scrollView = textView.enclosingScrollView as? BottomPinnedOutputScrollView
            else { return false }
            return tailReconciliation.expectedUserInteractionGeneration
                != scrollView.userInteractionGeneration
        }

        private func performTailScroll(
            in textView: NSTextView,
            forcesViewportLayout: Bool
        ) {
            let startedAt = ContinuousClock.now
            let label = forcesViewportLayout
                ? "main-output.tail-reconcile"
                : "main-output.scroll-bottom"
            PerformanceProbe.shared.measure(label, events: 1, thresholdMS: 50) {
                if forcesViewportLayout {
                    TextViewportProbe.layoutViewport(in: textView)
                }
                if let scrollView = textView.enclosingScrollView as? BottomPinnedOutputScrollView {
                    scrollView.scrollToBottomPreservingMode()
                } else {
                    textView.scrollToEndOfDocument(nil)
                }
            }
            let duration = ContinuousClock.now - startedAt
            tailReconciliation.workMilliseconds.append(
                max(0, Int(duration / .milliseconds(1)))
            )
        }

        private func emitTailReconciliationOutcome(_ outcome: String) {
            emitHealth(reason: tailReconciliationReason(outcome: outcome))
        }

        private func tailReconciliationReason(outcome: String) -> String {
            let elapsed: Int = if let startedAt = tailReconciliation.startedAt {
                max(0, Int((ContinuousClock.now - startedAt) / .milliseconds(1)))
            } else {
                0
            }
            let costs = tailReconciliation.workMilliseconds
                .map { "\($0)ms" }
                .joined(separator: "-")
            let total = tailReconciliation.workMilliseconds.reduce(0, +)
            return "tail-reconcile-\(tailReconciliation.generation)-\(outcome)"
                + "-\(tailReconciliation.source)-checks-\(tailReconciliation.check)"
                + "-costs-\(costs)-total-\(total)ms-elapsed-\(elapsed)ms"
        }
    }
#endif
