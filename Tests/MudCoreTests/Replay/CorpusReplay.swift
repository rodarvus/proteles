import Foundation
@testable import MudCore

/// S0a item 7 — the semantic layer replayed over the **local** recordings
/// corpus (`docs/plans/S0A_ITEM7_PROPOSAL.md`, GitHub #82).
///
/// Items 1–5 are tested one corpus line at a time. This is the whole-session
/// net: every `.jsonl` wire recording goes through the real pipeline, every
/// decoded line through `SemanticClassifier.events(forDisplayed:)` and every
/// GMCP message through `events(forGMCP:json:)` — the two production entry
/// points, nothing else — and the resulting event stream is held two ways:
///
/// - **Invariants** (``violations(in:)``) that need no baseline: a second,
///   independent recogniser for the tag grammar and the GMCP packages must
///   agree with the layer line for line.
/// - **Pin and diff**: a per-session baseline, written on first sight and
///   re-pinned deliberately (`PROTELES_REPLAY_PIN=1`), so any change in
///   classification across the corpus is a visible diff, never silent.
///
/// Nothing here leaves the machine: the corpus is read in place and the
/// baseline lives under `~/Documents/Proteles`, outside the repo. The run is
/// opt-in (`PROTELES_REPLAY=1`) so the default gate stays fast.
enum CorpusReplay {
    // MARK: - Types

    /// One classified event, positioned by the replay line it belongs to.
    /// `index` is the 0-based line number in the replayed output, so a diff
    /// points at a line you can find in the human `.log`. A GMCP event takes
    /// the index of the first line emitted after it.
    struct Event: Codable, Hashable, Comparable {
        let index: Int
        let name: String
        let category: String
        /// `tag:spellups`, `gmcp:comm.quest`, `pattern:level_up`.
        let source: String
        let payload: [String: String]

        static func < (lhs: Event, rhs: Event) -> Bool {
            (lhs.index, lhs.name, lhs.source) < (rhs.index, rhs.name, rhs.source)
        }
    }

    /// What a session classified to — the unit that is pinned.
    struct Session: Codable, Equatable {
        let name: String
        let lines: Int
        let gmcp: Int
        let events: [Event]
    }

    /// A replayed session plus the material the invariants need. Dropped
    /// after each session so the corpus never has to fit in memory at once.
    struct Replayed {
        let session: Session
        let lineTexts: [String]
        let gmcp: [GMCPMessage]
        /// Sound cues an unmuted soundpack played over the session, by file —
        /// see `CorpusReplay+Cues.swift`. Pinned separately from ``session``.
        let cues: [String: Int]
        /// The actionable-state pin (S0b) — see `CorpusReplay+State.swift`.
        var state = StateRecorder.Pin()
        /// The state pass's invariant violations.
        var stateViolations: [String] = []
    }

    struct Diff: Equatable {
        var added: [Event] = []
        var removed: [Event] = []
        var isEmpty: Bool {
            added.isEmpty && removed.isEmpty
        }
    }

    // MARK: - Replay

    static func sourceLabel(_ source: SemanticEvent.Source) -> String {
        switch source {
        case .gmcp(let package): "gmcp:\(package)"
        case .tag(let family): "tag:\(family)"
        case .pattern(let rule): "pattern:\(rule)"
        }
    }

    /// Replay one recording through the real pipeline and classify it.
    static func replay(_ url: URL) throws -> Replayed {
        let replayer = try SessionReplayer(url: url)
        var pipeline = LinePipeline()
        var texts: [String] = []
        var gmcp: [GMCPMessage] = []
        var events: [Event] = []
        var cues = CueCounter()
        var state = StateRecorder()
        func classify(_ line: Line) {
            state.observe(line, index: texts.count)
            for event in SemanticClassifier.events(forDisplayed: line) {
                cues.observe(event)
                events.append(Event(
                    index: texts.count,
                    name: event.name,
                    category: event.category.rawValue,
                    source: sourceLabel(event.source),
                    payload: event.payload
                ))
            }
            texts.append(line.text)
        }
        for chunk in replayer.chunks {
            let output = try pipeline.consume(Array(chunk.bytes))
            for message in output.gmcp {
                gmcp.append(message)
                cues.observe(gmcp: message)
                state.observe(gmcp: message)
                for event in SemanticClassifier.events(forGMCP: message.package, json: message.json) {
                    events.append(Event(
                        index: texts.count,
                        name: event.name,
                        category: event.category.rawValue,
                        source: sourceLabel(event.source),
                        payload: event.payload
                    ))
                }
            }
            for line in output.lines {
                classify(line)
            }
        }
        for line in pipeline.flush() {
            classify(line)
        }
        let session = Session(
            name: url.deletingPathExtension().lastPathComponent,
            lines: texts.count,
            gmcp: gmcp.count,
            events: events
        )
        return Replayed(
            session: session,
            lineTexts: texts,
            gmcp: gmcp,
            cues: cues.counts,
            state: state.pin,
            stateViolations: state.violations(session: session.name)
        )
    }

    /// Counts by `name/tier` — `affect_on/tag`, `quest_ready/gmcp`, …
    static func summary(_ session: Session) -> [String: Int] {
        var counts: [String: Int] = [:]
        for event in session.events {
            let tier = event.source.prefix { $0 != ":" }
            counts["\(event.name)/\(tier)", default: 0] += 1
        }
        return counts
    }

    static func diff(baseline: Session, current: Session) -> Diff {
        let before = Set(baseline.events)
        let after = Set(current.events)
        return Diff(
            added: after.subtracting(before).sorted(),
            removed: before.subtracting(after).sorted()
        )
    }

    /// The failure message for a changed session: the counts that moved, then
    /// the first `limit` changed events with their line text. Local output
    /// only — the text is never written anywhere but the test log.
    static func describe(
        _ diff: Diff,
        baseline: Session,
        current: Session,
        lineTexts: [String],
        limit: Int = 20
    ) -> String {
        var out = ["\(current.name): +\(diff.added.count) −\(diff.removed.count) events"]
        let before = summary(baseline)
        let after = summary(current)
        for key in Set(before.keys).union(after.keys).sorted() where before[key] != after[key] {
            out.append("  \(key): \(before[key] ?? 0) → \(after[key] ?? 0)")
        }
        let changes = diff.added.map { ("+", $0) } + diff.removed.map { ("−", $0) }
        for (sign, event) in changes.sorted(by: { $0.1 < $1.1 }).prefix(limit) {
            let text = event.index < lineTexts.count ? lineTexts[event.index] : "(line beyond current output)"
            out.append("  \(sign) \(event.index) \(event.name) [\(event.source)]  \(text.prefix(100))")
        }
        if changes.count > limit { out.append("  … \(changes.count - limit) more") }
        return out.joined(separator: "\n")
    }

    // MARK: - Where things live

    /// The user's real home — not `ProtelesPaths`, which the test runner
    /// redirects to a temporary sandbox (#45). Read-only access to the corpus;
    /// write access only to the baseline directory.
    static var realHome: URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    static var corpusDirectory: URL {
        realHome.appendingPathComponent("Documents/Proteles/Recordings", isDirectory: true)
    }

    static var baselineDirectory: URL {
        realHome.appendingPathComponent("Documents/Proteles/Diagnostics/replay-baseline", isDirectory: true)
    }

    /// Opt-in like the bench: a 650 MB replay must never ride inside the
    /// default `swift test`, where it would be skipped by habit.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PROTELES_REPLAY"] != nil
    }

    /// Overwrite every baseline — the deliberate re-pin after a reviewed change.
    static var shouldPin: Bool {
        ProcessInfo.processInfo.environment["PROTELES_REPLAY_PIN"] != nil
    }

    static func corpusURLs(in directory: URL = corpusDirectory) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func loadBaseline(named name: String, from directory: URL = baselineDirectory) -> Session? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func saveBaseline(_ session: Session, to directory: URL = baselineDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(session).write(
            to: directory.appendingPathComponent("\(session.name).json"),
            options: .atomic
        )
    }

    // MARK: - Invariants

    /// The six event tags per `help spelltags` / `help tags`, written here a
    /// second time on purpose: this recogniser must not share code with the
    /// router it checks. Field counts are the documented payload shapes.
    static let documentedTags: [String: (event: String, fields: Int)] = [
        "affon": ("affect_on", 2),
        "affoff": ("affect_off", 1),
        "recon": ("recovery_on", 2),
        "recoff": ("recovery_off", 1),
        "sfail": ("cast_failed", 4),
        "skillgain": ("skill_gain", 2)
    ]

    /// `comm.quest` actions per the reference `OnPluginBroadcast`, likewise
    /// restated independently.
    static let documentedQuestActions: [String: String] = [
        "ready": "quest_ready",
        "killed": "quest_target_killed",
        "comp": "quest_complete",
        "start": "quest_start",
        "warning": "quest_warning"
    ]

    /// The event a well-formed event-tag line must yield, or `nil` when the
    /// line is not one (prose, an entity tag, a malformed payload).
    static func documentedTagEvent(for text: String) -> String? {
        guard text.hasPrefix("{"), let close = text.firstIndex(of: "}") else { return nil }
        let marker = String(text[text.index(after: text.startIndex)..<close])
        guard let documented = documentedTags[marker] else { return nil }
        let fields = text[text.index(after: close)...].split(separator: ",", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int(String($0)) }
        guard numbers.count == fields.count, numbers.count == documented.fields else { return nil }
        if marker == "sfail", !(0...1).contains(numbers[1]) { return nil }
        return documented.event
    }

    static func usesSpellupTags(_ replayed: Replayed) -> Bool {
        replayed.lineTexts.contains { text in
            guard let event = documentedTagEvent(for: text) else { return false }
            return event != "skill_gain"
        }
    }

    /// Every invariant violation in one session, as human-readable lines.
    static func violations(in replayed: Replayed) -> [String] {
        let byIndex = Dictionary(grouping: replayed.session.events, by: \.index)
        var out: [String] = []
        out += tagViolations(replayed, byIndex: byIndex)
        out += vocabularyViolations(replayed)
        out += proseViolations(replayed, byIndex: byIndex)
        out += gmcpViolations(replayed)
        out += disabledPathViolations(replayed)
        return out
    }

    /// Tag recogniser agreement: each well-formed event tag yields exactly one
    /// tag-sourced event of the documented name; nothing else yields one.
    private static func tagViolations(_ replayed: Replayed, byIndex: [Int: [Event]]) -> [String] {
        var out: [String] = []
        for (index, text) in replayed.lineTexts.enumerated() {
            let tagEvents = (byIndex[index] ?? []).filter { $0.source.hasPrefix("tag:") }
            let expected = documentedTagEvent(for: text)
            let actual = tagEvents.map(\.name)
            let at = "\(replayed.session.name):\(index)"
            let sample = text.prefix(80)
            if let expected, actual != [expected] {
                out.append("\(at) expected [\(expected)] got \(actual)  \(sample)")
            } else if expected == nil, !tagEvents.isEmpty {
                out.append("\(at) tag event from a non-event-tag line: \(actual)  \(sample)")
            }
        }
        return out
    }

    /// Every name is in the vocabulary and carries the vocabulary's category.
    private static func vocabularyViolations(_ replayed: Replayed) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for event in replayed.session.events where !seen.contains(event.name) {
            seen.insert(event.name)
            let category = SemanticEventVocabulary.category(for: event.name)?.rawValue ?? "none"
            if category != event.category {
                let at = replayed.session.name
                out.append("\(at): \(event.name) has category \(event.category), vocabulary says \(category)")
            }
        }
        return out
    }

    /// A prose event's line matches, on its own, some rule carrying that name.
    private static func proseViolations(_ replayed: Replayed, byIndex: [Int: [Event]]) -> [String] {
        let rules = zip(SoundEventClassifier.rules, SoundEventClassifier.compiledRules)
        var out: [String] = []
        for (index, events) in byIndex {
            for event in events where event.source.hasPrefix("pattern:") {
                let text = replayed.lineTexts[index]
                let matched = rules
                    .contains { rule, matcher in rule.event == event.name && matcher?.match(text) != nil }
                if !matched {
                    let at = "\(replayed.session.name):\(index)"
                    out.append("\(at) \(event.name) matches no rule of that name  \(text.prefix(80))")
                }
            }
        }
        return out
    }

    /// A second recogniser over GMCP: repop count and quest actions agree.
    private static func gmcpViolations(_ replayed: Replayed) -> [String] {
        var expected: [String: Int] = [:]
        for message in replayed.gmcp {
            switch message.package.lowercased() {
            case "comm.repop":
                expected["zone_repop", default: 0] += 1
            case "comm.quest":
                let object = try? JSONSerialization.jsonObject(with: Data(message.json.utf8))
                let action = (object as? [String: Any])?["action"] as? String
                if let name = action.flatMap({ documentedQuestActions[$0] }) {
                    expected[name, default: 0] += 1
                }
            default:
                break
            }
        }
        let isCounted = { (event: Event) in
            event.source.hasPrefix("gmcp:comm.repop") || event.source.hasPrefix("gmcp:comm.quest")
        }
        var actual: [String: Int] = [:]
        for event in replayed.session.events where isCounted(event) {
            actual[event.name, default: 0] += 1
        }
        let session = replayed.session.name
        return Set(expected.keys).union(actual.keys).sorted().compactMap { name in
            let want = expected[name] ?? 0
            let got = actual[name] ?? 0
            return want == got ? nil : "\(session): \(name) expected \(want) from GMCP, got \(got)"
        }
    }

    /// The disabled path (`AARDWOLF_DATA_FEEDS.md` §8): a session with no
    /// spellup tags yields no affect events at all.
    private static func disabledPathViolations(_ replayed: Replayed) -> [String] {
        guard !usesSpellupTags(replayed) else { return [] }
        let affects = replayed.session.events.filter { $0.category == "affect" }
        guard !affects.isEmpty else { return [] }
        return ["\(replayed.session.name): no spellup tags, yet \(affects.count) affect events"]
    }
}

/// One pass over the corpus, shared by the two gated suites so a 650 MB replay
/// runs once per `swift test`, not once per test. Each session's lines are
/// released before the next is read.
final class CorpusReplayRun: @unchecked Sendable {
    struct Result {
        var sessions = 0
        var lines = 0
        var gmcp = 0
        var pinned = 0
        var withSpellupTags = 0
        var totals: [String: Int] = [:]
        var violations: [String] = []
        var diffReports: [String] = []
        var cueDiffReports: [String] = []
        var stateDiffReports: [String] = []
        var stateBlockTotals: [String: Int] = [:]
        var cueTotals: [String: Int] = [:]
        var elapsed: Duration = .zero
    }

    static let shared = CorpusReplayRun()
    private let lock = NSLock()
    private var cached: Result?

    func result() throws -> Result {
        try lock.withLock {
            if let cached { return cached }
            let result = try run()
            cached = result
            return result
        }
    }

    private func run() throws -> Result {
        let clock = ContinuousClock()
        let start = clock.now
        var result = Result()
        for url in CorpusReplay.corpusURLs() {
            let replayed = try CorpusReplay.replay(url)
            let session = replayed.session
            let violations = CorpusReplay.violations(in: replayed) + replayed.stateViolations
            result.violations += violations
            var status = "ok"
            if let baseline = CorpusReplay.loadBaseline(named: session.name), !CorpusReplay.shouldPin {
                let diff = CorpusReplay.diff(baseline: baseline, current: session)
                if !diff.isEmpty {
                    status = "DIFF +\(diff.added.count) −\(diff.removed.count)"
                    result.diffReports.append(CorpusReplay.describe(
                        diff, baseline: baseline, current: session, lineTexts: replayed.lineTexts
                    ))
                }
            } else {
                try CorpusReplay.saveBaseline(session)
                result.pinned += 1
                status = "pinned"
            }
            if let report = try CorpusReplay.checkCues(replayed) {
                result.cueDiffReports.append(report)
                status += " CUES DIFF"
            }
            result.cueTotals.merge(replayed.cues, uniquingKeysWith: +)
            if let report = try CorpusReplay.checkState(replayed) {
                result.stateDiffReports.append(report)
                status += " STATE DIFF"
            }
            result.stateBlockTotals.merge(replayed.state.blocks, uniquingKeysWith: +)
            result.sessions += 1
            result.lines += session.lines
            result.gmcp += session.gmcp
            if CorpusReplay.usesSpellupTags(replayed) { result.withSpellupTags += 1 }
            for (key, count) in CorpusReplay.summary(session) {
                result.totals[key, default: 0] += count
            }
            print("replay: \(session.name) lines=\(session.lines) gmcp=\(session.gmcp) "
                + "events=\(session.events.count) violations=\(violations.count) \(status)")
        }
        result.elapsed = clock.now - start
        print("replay: \(result.sessions) sessions, \(result.lines) lines, \(result.gmcp) gmcp, "
            + "\(result.pinned) pinned, \(result.withSpellupTags) with spellup tags, \(result.elapsed)")
        for (key, count) in result.totals.sorted(by: { $0.value > $1.value }) {
            print("replay:   \(key) \(count)")
        }
        for (file, count) in result.cueTotals.sorted(by: { $0.value > $1.value }) {
            print("replay:   cue \(file) \(count)")
        }
        for (feed, count) in result.stateBlockTotals.sorted(by: { $0.value > $1.value }) {
            print("replay:   state {\(feed)} blocks \(count)")
        }
        return result
    }
}
