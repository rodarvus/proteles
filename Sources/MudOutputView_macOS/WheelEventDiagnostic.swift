#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation

    /// Raw, text-free wheel fields captured on follow/review transitions.
    /// Instances are created only while Full Attribution diagnostics are wired.
    struct WheelEventDiagnostic {
        let beforeOriginY: CGFloat
        let timestamp: TimeInterval
        let scrollingDeltaX: CGFloat
        let scrollingDeltaY: CGFloat
        let legacyDeltaX: CGFloat
        let legacyDeltaY: CGFloat
        let hasPreciseScrollingDeltas: Bool
        let phase: UInt
        let momentumPhase: UInt
        let isDirectionInvertedFromDevice: Bool
        let modifierFlags: UInt
        let cgIsContinuous: Int64?
        let cgDeltaAxis1: Int64?
        let cgFixedPointDeltaAxis1: Double?
        let cgPointDeltaAxis1: Int64?
        let cgSourceProcessID: Int64?

        init(event: NSEvent, beforeOriginY: CGFloat) {
            self.beforeOriginY = beforeOriginY
            timestamp = event.timestamp
            scrollingDeltaX = event.scrollingDeltaX
            scrollingDeltaY = event.scrollingDeltaY
            legacyDeltaX = event.deltaX
            legacyDeltaY = event.deltaY
            hasPreciseScrollingDeltas = event.hasPreciseScrollingDeltas
            phase = event.phase.rawValue
            momentumPhase = event.momentumPhase.rawValue
            isDirectionInvertedFromDevice = event.isDirectionInvertedFromDevice
            modifierFlags = event.modifierFlags.rawValue

            let cgEvent = event.cgEvent
            cgIsContinuous = cgEvent?.getIntegerValueField(.scrollWheelEventIsContinuous)
            cgDeltaAxis1 = cgEvent?.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            cgFixedPointDeltaAxis1 = cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            cgPointDeltaAxis1 = cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            cgSourceProcessID = cgEvent?.getIntegerValueField(.eventSourceUnixProcessID)
        }

        func transcriptReason(afterOriginY: CGFloat, transition: String) -> String {
            "wheel-event "
                + "transition-\(transition) "
                + "precise-\(hasPreciseScrollingDeltas ? 1 : 0) "
                + "nseX-\(format(scrollingDeltaX)) nseY-\(format(scrollingDeltaY)) "
                + "legacyX-\(format(legacyDeltaX)) legacyY-\(format(legacyDeltaY)) "
                + "phase-\(phase) momentum-\(momentumPhase) "
                + "inverted-\(isDirectionInvertedFromDevice ? 1 : 0) modifiers-\(modifierFlags) "
                + "cgContinuous-\(optional(cgIsContinuous)) "
                + "cgAxis1-\(optional(cgDeltaAxis1)) "
                + "cgFixed1-\(optional(cgFixedPointDeltaAxis1)) "
                + "cgPoint1-\(optional(cgPointDeltaAxis1)) "
                + "sourcePID-\(optional(cgSourceProcessID)) "
                + "eventTime-\(format(timestamp)) "
                + "originBefore-\(format(beforeOriginY)) "
                + "originAfter-\(format(afterOriginY)) "
                + "originMove-\(format(afterOriginY - beforeOriginY))"
        }

        private func optional(_ value: Int64?) -> String {
            value.map(String.init) ?? "nil"
        }

        private func optional(_ value: Double?) -> String {
            value.map(format) ?? "nil"
        }

        private func format(_ value: Double) -> String {
            String(
                format: "%.4f",
                locale: Locale(identifier: "en_US_POSIX"),
                value
            )
        }
    }
#endif
