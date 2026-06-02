import Foundation

/// The kinds of diagnostic a MetricKit `MXDiagnosticPayload` can carry, keyed by
/// the JSON array they live under in `jsonRepresentation()`.
public enum DiagnosticKind: String, Sendable, CaseIterable {
    case crash = "crashDiagnostics"
    case hang = "hangDiagnostics"
    case cpuException = "cpuExceptionDiagnostics"
    case diskWriteException = "diskWriteExceptionDiagnostics"

    public var label: String {
        switch self {
        case .crash: "Crash"
        case .hang: "Hang"
        case .cpuException: "CPU exception"
        case .diskWriteException: "Disk-write exception"
        }
    }
}

/// A human-facing summary distilled from a MetricKit diagnostic payload's JSON.
/// Parsed **defensively** (the payload schema drifts across OS versions), so
/// every field is optional and a missing/renamed key just yields `nil` rather
/// than a decode failure. The raw payload JSON stays the source of truth on
/// disk; this is only what we show + copy into a bug report.
public struct DiagnosticSummary: Sendable, Equatable {
    /// Count of each diagnostic kind present in the payload.
    public var counts: [DiagnosticKind: Int]
    public var timeStampBegin: String?
    public var timeStampEnd: String?
    public var appVersion: String?
    public var appBuild: String?
    public var osVersion: String?
    public var exceptionType: String?
    public var signalName: String?
    public var terminationReason: String?
    /// The first few binary names down the attributed thread's stack — enough to
    /// see *where* it crashed (Proteles vs. a system framework) without the full
    /// (address-only, unsymbolicated) tree.
    public var topFrames: [String]

    /// The dominant kind for display (crash > hang > cpu > disk).
    public var primaryKind: DiagnosticKind? {
        DiagnosticKind.allCases.first { (counts[$0] ?? 0) > 0 }
    }

    /// A one-line headline, e.g. `Crash · SIGSEGV · v0.4.4 (32)`.
    public var headline: String {
        var parts: [String] = [primaryKind?.label ?? "Diagnostic"]
        if let cause = signalName ?? exceptionType { parts.append(cause) }
        if let appVersion {
            parts.append("v\(appVersion)" + (appBuild.map { " (\($0))" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

public extension DiagnosticSummary {
    /// Common Unix signal numbers → names (the most useful crash discriminator).
    private static let signalNames: [Int: String] = [
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE",
        10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE"
    ]

    /// Parse a summary from a MetricKit payload's `jsonRepresentation()` data.
    /// Returns an empty summary (no counts) if the JSON isn't a dictionary.
    static func parse(payloadJSON data: Data) -> DiagnosticSummary {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var counts: [DiagnosticKind: Int] = [:]
        for kind in DiagnosticKind.allCases {
            counts[kind] = (root[kind.rawValue] as? [[String: Any]])?.count ?? 0
        }
        var summary = DiagnosticSummary(
            counts: counts,
            timeStampBegin: root["timeStampBegin"] as? String,
            timeStampEnd: root["timeStampEnd"] as? String,
            appVersion: nil,
            appBuild: nil,
            osVersion: nil,
            exceptionType: nil,
            signalName: nil,
            terminationReason: nil,
            topFrames: []
        )
        // Pull detail from the first crash diagnostic (else the first of any kind).
        let kind = summary.primaryKind ?? .crash
        guard let first = (root[kind.rawValue] as? [[String: Any]])?.first else { return summary }
        let meta = first["diagnosticMetaData"] as? [String: Any] ?? [:]
        summary.appVersion = meta["appVersion"] as? String
        summary.appBuild = meta["appBuildVersion"] as? String
        summary.osVersion = meta["osVersion"] as? String
        summary.terminationReason = meta["terminationReason"] as? String
        if let exc = meta["exceptionType"] { summary.exceptionType = "EXC \(exc)" }
        if let sig = meta["signal"] as? Int { summary.signalName = signalNames[sig] ?? "signal \(sig)" }
        summary.topFrames = Self.frames(from: first["callStackTree"] as? [String: Any], limit: 6)
        return summary
    }

    /// Depth-first walk of the attributed thread's stack, collecting distinct
    /// binary names (the cheap, unsymbolicated "where" signal).
    private static func frames(from tree: [String: Any]?, limit: Int) -> [String] {
        guard let stacks = tree?["callStacks"] as? [[String: Any]] else { return [] }
        let attributed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var names: [String] = []
        var stack = (attributed?["callStackRootFrames"] as? [[String: Any]]) ?? []
        while let frame = stack.first, names.count < limit {
            stack.removeFirst()
            if let name = frame["binaryName"] as? String, names.last != name { names.append(name) }
            if let sub = frame["subFrames"] as? [[String: Any]] { stack.insert(contentsOf: sub, at: 0) }
        }
        return names
    }
}
