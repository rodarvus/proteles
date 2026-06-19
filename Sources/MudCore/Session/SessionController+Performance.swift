import Foundation

extension SessionController {
    @discardableResult
    func measureSessionPhase<T>(
        _ phase: String,
        events: Int = 0,
        thresholdMS: Int,
        _ body: () async -> T
    ) async -> T {
        let start = ContinuousClock.now
        let value = await body()
        PerformanceProbe.shared.recordPhase(
            phase,
            duration: ContinuousClock.now - start,
            events: events,
            thresholdMS: thresholdMS
        )
        return value
    }
}
