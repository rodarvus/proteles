import Foundation

/// The corpus scenario run's report: what each test-plan scenario was
/// replayed against and what held. Written under `~/Documents/Proteles`,
/// outside the repo, since it quotes the recordings.
enum ScenarioReport {
    static var directory: URL {
        CorpusReplay.realHome.appendingPathComponent(
            "Documents/Proteles/Diagnostics/scenarios",
            isDirectory: true
        )
    }

    static func markdown(
        consider: [ConsiderScenarioReplay.Result],
        walks: [WalkScenarioReplay.Result],
        elapsed: Duration
    ) -> String {
        var out = ["# Scenario replay — \(Date().formatted(.iso8601))", ""]
        out += ["\(consider.count) sessions for Consider, \(walks.count) for walks, in \(elapsed).", ""]
        out += considerSection(consider)
        out += walkSection(walks)
        return out.joined(separator: "\n") + "\n"
    }

    private static func considerSection(_ results: [ConsiderScenarioReplay.Result]) -> [String] {
        var counts = ConsiderAudit.Counts()
        var arrivals = ConsiderScenarioReplay.Arrivals()
        var would = ConsiderScenarioReplay.WouldSend()
        var violations: [String] = []
        var misses: [String] = []
        for result in results {
            counts.add(result.audit.counts)
            arrivals.add(result.arrivals)
            would.add(result.wouldSend)
            violations += result.audit.violations
            misses += result.audit.missSamples
        }
        let perHour = would.hours > 0 ? Double(would.total) / would.hours : 0
        var out = ["## Consider", "", "| Scenario | Instances | Held |", "|---|---|---|"]
        out.append("| C1 kills stay dead (in a list of 2+) | \(counts.deadInMultiMobLists) | "
            + "\(violations.count { $0.contains("revived") }) revived |")
        out.append("| C1 dead marks with their kill line | \(counts.deadMarks) | "
            + "\(violations.count { $0.contains("dead without") }) without |")
        out.append("| C2 departures marked, \(counts.verbs.count) verbs | \(counts.leftMarks) | "
            + "\(violations.count { $0.contains("left without") || $0.contains("left with no") }) unbacked; "
            + "\(counts.missedDepartures) departure-shaped lines unmarked |")
        let settled = "\(arrivals.confirmed) listed it, \(arrivals.contradicted) didn't"
        out.append("| C3 arrival rows | \(counts.arrivalRows) | next consider in the room: "
            + "\(settled), \(arrivals.unchecked) none |")
        out.append("| C4 thunderclap lines | \(counts.thunderclaps) | "
            + "\(violations.count { $0.contains("player's arrival") }) made a row |")
        out.append("| C5 repops → would refresh | \(would.byReason["comm.repop"] ?? 0) | — |")
        out.append("| C6 flees marked | \(counts.fledMarks) | "
            + "\(violations.count { $0.contains("fled without") }) unbacked |")
        out += [
            "",
            "**What auto-refresh would send** (`conw on`, replayed beside the list): "
                + "\(would.total) considers over \(String(format: "%.0f", would.hours)) h "
                + "(\(String(format: "%.1f", perHour))/h; the recordings sent \(would.recordedConsiders)); "
                + "peak \(would.peakIn10s) in 10 s; \(would.passingThrough) in a room left within 2 s; "
                + "\(would.whileFighting) while fighting.",
            ""
        ]
        out.append("By reason: " + would.byReason.sorted { $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        out += [
            "",
            "Departure verbs: " + counts.verbs.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "),
            ""
        ]
        out += [
            "### Arrival names the next consider didn't list (top 30)",
            "",
            "| Name | listed | not | none |",
            "|---|---|---|---|"
        ]
        let unlisted = arrivals.byName.filter { $0.value[1] > 0 }.sorted { $0.value[1] > $1.value[1] }
        for (name, tally) in unlisted.prefix(30) {
            out.append("| \(name) | \(tally[0]) | \(tally[1]) | \(tally[2]) |")
        }
        out += ["", "### Violations (\(violations.count))", ""] + byKind(violations)
            + [""] + violations.prefix(60).map { "- \($0)" }
        out += ["", "### Unmarked departure-shaped lines (sample)", ""] + misses.prefix(40).map { "- \($0)" }
        return out + [""]
    }

    private static func walkSection(_ results: [WalkScenarioReplay.Result]) -> [String] {
        var total = WalkScenarioReplay.Result(name: "all")
        for result in results {
            total.windows.merge(result.windows, uniquingKeysWith: +)
            total.failures.merge(result.failures, uniquingKeysWith: +)
            total.violations += result.violations
            total.resolved += result.resolved
            total.unresolved += result.unresolved
            total.unresolvedOwingEnd += result.unresolvedOwingEnd
            total.paced += result.paced
            total.noRoute += result.noRoute
            total.cancelled += result.cancelled
            total.routeAgreed += result.routeAgreed
            total.routeCompared += result.routeCompared
            total.broadcasts += result.broadcasts
        }
        var out = ["## Walks", "", "| How the recorded walk ended | Windows | Violations |", "|---|---|---|"]
        for recorded in WalkAudit.Recorded.allCases {
            let tag = "[\(recorded.rawValue)]"
            out.append("| \(recorded.rawValue) | \(total.windows[recorded] ?? 0) | "
                + "\(total.violations.count { $0.contains(tag) }) |")
        }
        out += [
            "",
            "Failed moves by line: " + total.failures.sorted { $0.value > $1.value }
                .map { "“\($0.key)” \($0.value)" }.joined(separator: ", ")
        ]
        out += [
            "",
            "In the replay: \(total.resolved) finished, \(total.cancelled) cancelled by a failed move, "
                + "\(total.unresolved) still walking at \(Int(WalkScenarioReplay.cap)) s "
                + "(\(total.unresolvedOwingEnd) owing their end: the silent stall), \(total.paced) paced "
                + "(not judged), \(total.noRoute) found no route.",
            "First segment matched the recording in \(total.routeAgreed) of \(total.routeCompared); "
                + "plugins heard \(total.broadcasts) running broadcasts.",
            ""
        ]
        out += ["### Violations (\(total.violations.count))", ""] + byKind(total.violations) + [""]
            + total.violations.prefix(60).map { "- \($0)" }
        return out + [""]
    }

    /// Violations counted by what broke: the session and time dropped, and
    /// what follows a colon (a name, a line, a command).
    static func byKind(_ violations: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for violation in violations {
            let message = violation.split(separator: " ").dropFirst(2).joined(separator: " ")
            let kind = message.split(separator: ":").first.map(String.init) ?? message
            let route = message.hasSuffix("(off the recorded route)") ? " (off route)" : ""
            counts[kind + (kind.hasSuffix("route)") ? "" : route), default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { "- \($0.value) × \($0.key)" }
    }

    static func write(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let url = directory.appendingPathComponent("report-\(stamp).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

extension ConsiderAudit.Counts {
    mutating func add(_ other: Self) {
        snapshots += other.snapshots
        deadMarks += other.deadMarks
        deadInMultiMobLists += other.deadInMultiMobLists
        leftMarks += other.leftMarks
        fledMarks += other.fledMarks
        arrivalRows += other.arrivalRows
        missedDepartures += other.missedDepartures
        thunderclaps += other.thunderclaps
        verbs.merge(other.verbs, uniquingKeysWith: +)
    }
}

extension ConsiderScenarioReplay.Arrivals {
    mutating func add(_ other: Self) {
        confirmed += other.confirmed
        contradicted += other.contradicted
        unchecked += other.unchecked
        byName.merge(other.byName) { zip($0, $1).map(+) }
    }
}

extension ConsiderScenarioReplay.WouldSend {
    mutating func add(_ other: Self) {
        byReason.merge(other.byReason, uniquingKeysWith: +)
        passingThrough += other.passingThrough
        whileFighting += other.whileFighting
        peakIn10s = max(peakIn10s, other.peakIn10s)
        recordedConsiders += other.recordedConsiders
        hours += other.hours
    }
}
