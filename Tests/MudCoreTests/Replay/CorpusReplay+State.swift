import Foundation
@testable import MudCore

/// The actionable-state frame replayed over the corpus (S0b item 1, #84;
/// `docs/plans/S0B_ITEM1_PROPOSAL.md` §3.5). The production tracker ingests
/// every decoded line and GMCP message in order, and the result is held two
/// ways, as for events and cues:
///
/// - **Invariant:** an independent count of opening/closing marker pairs,
///   by plain prefix matching, must equal the tracker's completed blocks per
///   feed, and no block may be incomplete. Each incomplete block is listed by
///   line index, so a real one is visible rather than silently dropped.
///   Likewise, independent counts of tag lines (by prefix) and GMCP packages
///   (by name) must equal each tag-line and GMCP feed's arrivals.
/// - **Pin:** which feeds a session saw and its blocks per feed, in its own
///   baseline. Later S0b items add their entities' pins here.
struct StateRecorder {
    /// What is pinned per session.
    struct Pin: Codable, Equatable {
        var seen: [String] = []
        var blocks: [String: Int] = [:]
    }

    private var tracker = ActionableStateTracker()
    private var open: (feed: ActionableState.Feed, index: Int)?
    private(set) var independentBlocks: [String: Int] = [:]
    private(set) var independentArrivals: [String: Int] = [:]
    private(set) var incomplete: [String] = []

    var pin: Pin {
        var pin = Pin()
        for feed in ActionableState.Feed.allCases where tracker.state.status(of: feed).isSeen {
            pin.seen.append(feed.rawValue)
            if feed.kind == .tagBlock { pin.blocks[feed.rawValue] = tracker.state.status(of: feed).blocks }
        }
        return pin
    }

    mutating func observe(_ line: Line, index: Int) {
        let before = tracker.state
        _ = tracker.ingest(line)
        countIndependently(line.text, index: index)
        for feed in ActionableState.Feed.allCases where feed.kind == .tagBlock {
            let was = before.status(of: feed).incompleteBlocks
            if tracker.state.status(of: feed).incompleteBlocks > was {
                let reason = tracker.state.status(of: feed).lastIncomplete?.reason.rawValue ?? "?"
                incomplete.append("\(index): {\(feed.rawValue)} block \(reason)")
            }
        }
    }

    mutating func observe(gmcp message: GMCPMessage) {
        _ = tracker.ingest(gmcpPackage: message.package)
        let name = message.package.lowercased()
        if ActionableState.Feed.allCases.contains(where: { $0.kind == .gmcp && $0.rawValue == name }) {
            independentArrivals[name, default: 0] += 1
        }
    }

    /// The tracker's arrivals per tag-line and GMCP feed, zeros omitted.
    var arrivals: [String: Int] {
        var out: [String: Int] = [:]
        for feed in ActionableState.Feed.allCases where feed.kind != .tagBlock {
            let count = tracker.state.status(of: feed).arrivals
            if count > 0 { out[feed.rawValue] = count }
        }
        return out
    }

    /// The second recogniser: `{family}` / `{family args}` opens, `{/family}`
    /// closes, and a pair counts only when nothing interrupts it.
    private mutating func countIndependently(_ text: String, index: Int) {
        guard text.hasPrefix("{") else { return }
        for feed in ActionableState.Feed.allCases where feed.kind == .tagLine {
            if text.hasPrefix("{\(feed.rawValue)}") || text.hasPrefix("{\(feed.rawValue) ") {
                independentArrivals[feed.rawValue, default: 0] += 1
                return
            }
        }
        for feed in ActionableState.Feed.allCases where feed.kind == .tagBlock {
            let name = feed.rawValue
            if text.hasPrefix("{/\(name)}") {
                if open?.feed == feed { independentBlocks[name, default: 0] += 1 }
                open = nil
                return
            }
            if text.hasPrefix("{\(name)}") || text.hasPrefix("{\(name) ") {
                open = (feed, index)
                return
            }
        }
    }

    /// Disagreements with the independent count, and every incomplete block.
    func violations(session: String) -> [String] {
        var out = incomplete.map { "\(session) state: incomplete \($0)" }
        let mine = pin.blocks.filter { $0.value > 0 }
        if mine != independentBlocks {
            out.append("\(session) state: blocks \(mine.sorted { $0.key < $1.key }) "
                + "≠ independent \(independentBlocks.sorted { $0.key < $1.key })")
        }
        if arrivals != independentArrivals {
            out.append("\(session) state: arrivals \(arrivals.sorted { $0.key < $1.key }) "
                + "≠ independent \(independentArrivals.sorted { $0.key < $1.key })")
        }
        return out
    }
}

extension CorpusReplay {
    static var stateBaselineDirectory: URL {
        realHome.appendingPathComponent(
            "Documents/Proteles/Diagnostics/replay-state-baseline",
            isDirectory: true
        )
    }

    static func loadStatePin(at url: URL) -> StateRecorder.Pin? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StateRecorder.Pin.self, from: data)
    }

    /// Compare a session's state pin to its baseline (pinning on first sight
    /// or under `PROTELES_REPLAY_PIN`). Returns a report when they differ.
    static func checkState(
        _ replayed: Replayed,
        directory: URL = stateBaselineDirectory
    ) throws -> String? {
        let name = replayed.session.name
        let url = directory.appendingPathComponent("\(name).json")
        if !shouldPin, let baseline = loadStatePin(at: url) {
            guard baseline != replayed.state else { return nil }
            return "\(name): state differs\n  was \(baseline)\n  now \(replayed.state)"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(replayed.state).write(to: url)
        return nil
    }
}
