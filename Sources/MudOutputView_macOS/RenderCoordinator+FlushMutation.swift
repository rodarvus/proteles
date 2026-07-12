#if os(macOS)
    import Foundation

    extension RenderCoordinator {
        struct FlushMutation {
            var didAppend = false
            var didRemoveTail = false
            var trimmedLines = 0
            var appendedCount = 0
            var maxArrivalLatency: TimeInterval = 0
            var limitChange: (label: String, evicted: Int)?
            var forceEvictionTrim = false
        }
    }
#endif
