import Foundation

/// A captured MetricKit diagnostic on disk: the raw payload JSON plus its parsed
/// summary. The JSON is the source of truth; the summary is what the UI shows.
public struct DiagnosticReport: Sendable, Identifiable, Equatable {
    public var id: String // file name stem, e.g. "diagnostic-20260602-204117"
    public var url: URL
    public var capturedAt: Date
    public var summary: DiagnosticSummary
}

/// On-device store for MetricKit diagnostic payloads, under
/// `~/Library/Application Support/com.proteles.ProtelesApp/diagnostics/`
/// (sibling to `recordings/`). Pure file I/O — no MetricKit dependency — so it's
/// unit-testable against a temp directory; the macOS app injects the actual
/// `MXMetricManagerSubscriber` and hands payloads here. Nothing leaves the
/// machine; reports are surfaced only when the user has opted in.
public struct DiagnosticsStore: Sendable {
    public enum StoreError: Error { case noApplicationSupport }

    let directory: URL

    /// Default location (creating it); pass `directory` in tests.
    public init(directory: URL? = nil) throws {
        let fileManager = FileManager.default
        if let directory {
            self.directory = directory
        } else {
            // `~/Documents/Proteles/State/diagnostics/` (#43).
            guard let dir = try? ProtelesPaths.diagnosticsDirectory(fileManager: fileManager)
            else { throw StoreError.noApplicationSupport }
            self.directory = dir
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private static let stampFormat = "yyyyMMdd-HHmmss"

    private static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = stampFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter // local time, matching the recordings convention
    }

    /// Persist a payload's `jsonRepresentation()` data, then prune to the cap.
    /// Returns the written file URL.
    @discardableResult
    public func save(
        payloadJSON data: Data,
        capturedAt: Date = Date(),
        keepingLast cap: Int = 20
    ) throws -> URL {
        let stamp = Self.stampFormatter().string(from: capturedAt)
        let url = directory.appendingPathComponent("diagnostic-\(stamp).json")
        try data.write(to: url, options: .atomic)
        prune(keepingLast: cap)
        return url
    }

    /// All stored reports, newest first.
    public func reports() -> [DiagnosticReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))
            ?? []
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("diagnostic-") }
            .compactMap(report(at:))
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    private func report(at url: URL) -> DiagnosticReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let stamp = String(stem.dropFirst("diagnostic-".count))
        let captured = Self.stampFormatter().date(from: stamp)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
        return DiagnosticReport(
            id: stem,
            url: url,
            capturedAt: captured,
            summary: DiagnosticSummary.parse(payloadJSON: data)
        )
    }

    /// Keep only the newest `cap` reports, deleting the rest.
    public func prune(keepingLast cap: Int) {
        for report in reports().dropFirst(max(0, cap)) {
            delete(report)
        }
    }

    public func delete(_ report: DiagnosticReport) {
        try? FileManager.default.removeItem(at: report.url)
    }

    public func deleteAll() {
        for report in reports() {
            delete(report)
        }
    }

    /// The recording (`session-*.log`) that was running when the diagnostic
    /// fired: the latest session whose start instant is at or before the crash
    /// window's end. Compares parsed **absolute `Date`s** (recording filename in
    /// local time, payload timestamp in its own `+0000` offset), never raw
    /// strings — so the UTC-vs-local trap can't bite. `nil` if none matches.
    public func correlatedRecording(for report: DiagnosticReport, recordingsDirectory: URL) -> String? {
        guard let crashEnd = Self.parsePayloadDate(report.summary.timeStampEnd)
            ?? Optional(report.capturedAt) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        ))
            ?? []
        let candidates: [(start: Date, name: String)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("session-"), name.hasSuffix(".log") else { return nil }
            let stamp = name.dropFirst("session-".count).dropLast(".log".count)
            guard let start = Self.stampFormatter().date(from: String(stamp)) else { return nil }
            return (start, name)
        }
        return candidates.filter { $0.start <= crashEnd }.max { $0.start < $1.start }?.name
    }

    /// Parse a MetricKit payload timestamp like `2026-06-02 19:30:00 +0000`.
    private static func parsePayloadDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: string)
    }

    /// A sanitized, user-content-free text block for pasting into a bug report —
    /// headline, versions, termination reason, and the top frames. Never includes
    /// recording/MUD content.
    public func summaryText(for report: DiagnosticReport) -> String {
        let summary = report.summary
        var lines = ["Proteles diagnostic — \(summary.headline)"]
        if let os = summary.osVersion { lines.append("OS: \(os)") }
        if let begin = summary.timeStampBegin, let end = summary.timeStampEnd {
            lines.append("Window: \(begin) – \(end)")
        }
        if let reason = summary.terminationReason { lines.append("Termination: \(reason)") }
        let present = DiagnosticKind.allCases
            .compactMap { kind -> String? in
                let count = summary.counts[kind] ?? 0
                return count > 0 ? "\(count) \(kind.label.lowercased())" : nil
            }
            .joined(separator: ", ")
        if !present.isEmpty { lines.append("Diagnostics: \(present)") }
        if !summary.topFrames.isEmpty {
            lines.append("Top frames:")
            lines.append(contentsOf: summary.topFrames.map { "  - \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
