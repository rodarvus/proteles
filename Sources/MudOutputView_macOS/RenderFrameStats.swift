#if os(macOS)
    import Foundation

    /// Per-flush render telemetry: paint cost, arrival-to-paint latency, and
    /// the live rendered-document size.
    public struct RenderFrameStats: Sendable {
        public let flushDuration: Duration
        public let appendedLines: Int
        public let maxArrivalLatency: TimeInterval
        public let documentLines: Int
        public let documentUTF16Length: Int

        public init(
            flushDuration: Duration,
            appendedLines: Int,
            maxArrivalLatency: TimeInterval,
            documentLines: Int = 0,
            documentUTF16Length: Int = 0
        ) {
            self.flushDuration = flushDuration
            self.appendedLines = appendedLines
            self.maxArrivalLatency = maxArrivalLatency
            self.documentLines = documentLines
            self.documentUTF16Length = documentUTF16Length
        }
    }
#endif
