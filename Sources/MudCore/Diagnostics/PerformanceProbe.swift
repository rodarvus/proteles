import Foundation

/// Lightweight, process-wide performance attribution for field recordings.
///
/// The UI-stall watchdog can only say that the main actor woke late. This probe
/// gives that note recent context without recording gameplay text or payloads:
/// phase name, duration, event count, and login-relative timing only.
public final class PerformanceProbe: @unchecked Sendable {
    public static let shared = PerformanceProbe()

    public enum Mode: String, Sendable, CaseIterable {
        case off
        case stallOnly
        case full
    }

    public struct Snapshot: Sendable, Equatable {
        public let phase: String
        public let durationMS: Int
        public let eventCount: Int
        public let timestamp: Date
        public let inGameElapsed: TimeInterval?
        public let isStartupWindow: Bool
    }

    public struct Summary: Sendable, Equatable {
        public let interval: TimeInterval
        public let measuredPhases: Int
        public let slowPhases: Int
        public let maxDurationMS: Int
        public let maxPhase: String?
    }

    public var startupWindow: TimeInterval = 120
    public var stallAttributionWindow: TimeInterval = 5
    public var recentPressureWindow: TimeInterval = 10

    private let lock = NSLock()
    private var mode: Mode = .stallOnly
    private var inGameAt: Date?
    private var lastSnapshot: Snapshot?
    private var recentSamples: [PhaseSample] = []
    private var pendingNotes: [String] = []
    private var summaryStartedAt = Date()
    private var measuredPhases = 0
    private var slowPhases = 0
    private var maxDurationMS = 0
    private var maxPhase: String?

    public init() {}

    public func setMode(_ mode: Mode) {
        lock.withLock {
            self.mode = mode
            if mode != .full {
                lastSnapshot = nil
                recentSamples.removeAll()
                pendingNotes.removeAll()
                measuredPhases = 0
                slowPhases = 0
                maxDurationMS = 0
                maxPhase = nil
            }
        }
    }

    public var recordsStalls: Bool {
        lock.withLock { mode != .off }
    }

    public var recordsAttribution: Bool {
        lock.withLock { mode == .full }
    }

    public func reset(now: Date = Date()) {
        lock.withLock {
            inGameAt = nil
            lastSnapshot = nil
            recentSamples.removeAll()
            pendingNotes.removeAll()
            summaryStartedAt = now
            measuredPhases = 0
            slowPhases = 0
            maxDurationMS = 0
            maxPhase = nil
        }
    }

    public func markInGame(at timestamp: Date = Date()) {
        lock.withLock {
            if inGameAt == nil {
                inGameAt = timestamp
            }
        }
    }

    @discardableResult
    public func measure<T>(
        _ phase: String,
        events: Int = 0,
        thresholdMS: Int,
        _ body: () throws -> T
    ) rethrows -> T {
        guard recordsAttribution else { return try body() }
        let start = ContinuousClock.now
        do {
            let value = try body()
            recordPhase(
                phase,
                duration: ContinuousClock.now - start,
                events: events,
                thresholdMS: thresholdMS
            )
            return value
        } catch {
            recordPhase(
                phase,
                duration: ContinuousClock.now - start,
                events: events,
                thresholdMS: thresholdMS
            )
            throw error
        }
    }

    public func recordPhase(
        _ phase: String,
        duration: Duration,
        events: Int = 0,
        thresholdMS: Int,
        at timestamp: Date = Date()
    ) {
        let durationMS = max(0, Int(duration / .milliseconds(1)))
        lock.withLock {
            guard mode == .full else { return }
            measuredPhases += 1
            if durationMS > maxDurationMS {
                maxDurationMS = durationMS
                maxPhase = phase
            }
            recentSamples.append(PhaseSample(
                phase: phase,
                durationMS: durationMS,
                events: events,
                timestamp: timestamp,
                isSlow: durationMS >= thresholdMS
            ))
            pruneRecentSamplesLocked(now: timestamp)
            guard durationMS >= thresholdMS else { return }
            slowPhases += 1
            let snapshot = makeSnapshotLocked(
                phase: phase,
                durationMS: durationMS,
                events: events,
                timestamp: timestamp
            )
            lastSnapshot = snapshot
            pendingNotes.append("perf: \(format(snapshot))")
        }
    }

    public func recordEventSummary(
        _ phase: String,
        events: Int,
        fields: [(String, Int)],
        thresholdEvents: Int
    ) {
        guard events >= thresholdEvents else { return }
        lock.withLock {
            guard mode == .full else { return }
            let detail = fields
                .map { "\($0.0) \($0.1)" }
                .joined(separator: " ")
            pendingNotes.append(
                "perf-burst: \(phase) events \(events) \(detail) "
                    + "\(formatLoginTimingLocked(Date()))"
            )
        }
    }

    public func stallNote(blockedMS: Int, at timestamp: Date = Date()) -> String {
        lock.withLock {
            let prefix = "UI stall: main thread blocked ~\(blockedMS)ms"
            let login = formatLoginTimingLocked(timestamp)
            let recent = formatRecentPressureIfRecordingLocked(at: timestamp)
            guard let lastSnapshot else {
                return "\(prefix); \(login); last perf phase: none\(recent)"
            }
            let age = timestamp.timeIntervalSince(lastSnapshot.timestamp)
            guard age <= stallAttributionWindow else {
                return "\(prefix); \(login); last perf phase: stale "
                    + "\(String(format: "%.1fs", age)) ago \(format(lastSnapshot))"
                    + recent
            }
            return "\(prefix); \(login); last perf phase: \(format(lastSnapshot))\(recent)"
        }
    }

    public func drainPendingNotes() -> [String] {
        lock.withLock {
            guard mode == .full else {
                pendingNotes.removeAll()
                return []
            }
            let notes = pendingNotes
            pendingNotes.removeAll(keepingCapacity: true)
            return notes
        }
    }

    public func drainSummary(now: Date = Date()) -> Summary? {
        lock.withLock {
            guard mode == .full else {
                summaryStartedAt = now
                measuredPhases = 0
                slowPhases = 0
                maxDurationMS = 0
                maxPhase = nil
                return nil
            }
            let interval = now.timeIntervalSince(summaryStartedAt)
            guard measuredPhases > 0 else {
                summaryStartedAt = now
                return nil
            }
            let summary = Summary(
                interval: interval,
                measuredPhases: measuredPhases,
                slowPhases: slowPhases,
                maxDurationMS: maxDurationMS,
                maxPhase: maxPhase
            )
            summaryStartedAt = now
            measuredPhases = 0
            slowPhases = 0
            maxDurationMS = 0
            maxPhase = nil
            return summary
        }
    }

    public func format(_ summary: Summary) -> String {
        let interval = Int(summary.interval.rounded())
        let maxPart = summary.maxPhase.map { "\($0) \(summary.maxDurationMS)ms" } ?? "none"
        return "perf-summary: \(interval)s phases \(summary.measuredPhases) "
            + "slow \(summary.slowPhases) max \(maxPart)"
    }

    private func makeSnapshotLocked(
        phase: String,
        durationMS: Int,
        events: Int,
        timestamp: Date
    ) -> Snapshot {
        let elapsed = inGameAt.map { timestamp.timeIntervalSince($0) }
        return Snapshot(
            phase: phase,
            durationMS: durationMS,
            eventCount: events,
            timestamp: timestamp,
            inGameElapsed: elapsed,
            isStartupWindow: elapsed.map { $0 >= 0 && $0 < startupWindow } ?? false
        )
    }

    private func format(_ snapshot: Snapshot) -> String {
        "\(snapshot.phase) \(snapshot.durationMS)ms events \(snapshot.eventCount) "
            + "\(formatLoginTiming(snapshot.inGameElapsed)) "
            + "\(snapshot.isStartupWindow ? "startup" : "live")"
    }

    private func formatRecentPressureIfRecordingLocked(at timestamp: Date) -> String {
        guard mode == .full else { return "" }
        pruneRecentSamplesLocked(now: timestamp)
        let samples = recentSamples.filter {
            timestamp.timeIntervalSince($0.timestamp) <= recentPressureWindow
        }
        let window = String(format: "%.0fs", recentPressureWindow)
        guard !samples.isEmpty else {
            return "; recent perf: none in last \(window)"
        }
        let slowCount = samples.filter(\.isSlow).count
        let eventCount = samples.reduce(0) { $0 + $1.events }
        let maxSample = samples.max { lhs, rhs in lhs.durationMS < rhs.durationMS }
        let maxPart = maxSample.map { "\($0.phase) \($0.durationMS)ms" } ?? "none"
        return "; recent perf: last \(window) phases \(samples.count) "
            + "slow \(slowCount) events \(eventCount) max \(maxPart) "
            + "top \(formatTopPhases(samples))"
    }

    private func formatTopPhases(_ samples: [PhaseSample]) -> String {
        var groups: [String: (count: Int, maxMS: Int)] = [:]
        for sample in samples {
            let current = groups[sample.phase] ?? (count: 0, maxMS: 0)
            groups[sample.phase] = (
                count: current.count + 1,
                maxMS: max(current.maxMS, sample.durationMS)
            )
        }
        return groups
            .sorted {
                if $0.value.count != $1.value.count {
                    return $0.value.count > $1.value.count
                }
                if $0.value.maxMS != $1.value.maxMS {
                    return $0.value.maxMS > $1.value.maxMS
                }
                return $0.key < $1.key
            }
            .prefix(3)
            .map { "\($0.key) x\($0.value.count) max \($0.value.maxMS)ms" }
            .joined(separator: ", ")
    }

    private func pruneRecentSamplesLocked(now: Date) {
        let keepWindow = max(recentPressureWindow, stallAttributionWindow) + 1
        recentSamples.removeAll {
            now.timeIntervalSince($0.timestamp) > keepWindow
        }
    }

    private func formatLoginTimingLocked(_ timestamp: Date) -> String {
        formatLoginTiming(inGameAt.map { timestamp.timeIntervalSince($0) })
    }

    private func formatLoginTiming(_ elapsed: TimeInterval?) -> String {
        guard let elapsed else { return "login unknown" }
        if elapsed < 0 {
            return "login\(String(format: "%+.1fs", elapsed))"
        }
        return "login+\(String(format: "%.1fs", elapsed))"
    }
}

private struct PhaseSample: Equatable {
    let phase: String
    let durationMS: Int
    let events: Int
    let timestamp: Date
    let isSlow: Bool
}
