import Foundation
@testable import MudCore

/// The cues an unmuted soundpack plays over a replayed session, pinned per
/// session like the event baseline (`docs/plans/S1_ITEM1_PROPOSAL.md` §5).
///
/// The counter drives the production composition: GMCP through
/// ``NativePluginRegistry/onGMCP(package:json:)``, displayed-line events
/// through ``NativePluginRegistry/onSemanticEvent(_:)``. It does not care
/// which of those paths a cue comes from, so the same pin holds across a
/// change that moves cues from one path to the other — that is the point.
struct CueCounter {
    private var registry: NativePluginRegistry
    private(set) var counts: [String: Int] = [:]

    init() {
        registry = NativePluginRegistry()
        registry.register(ChatEcho())
        registry.register(Soundpack(configURL: nil))
        // Unmute through the registry: `register` re-runs `install()`, which
        // re-reads config and would undo an unmute made before it. The
        // confirmation cue is not counted.
        _ = registry.handleCommand("spmute")
        precondition(registry.wantsSemanticEvents, "the soundpack must be unmuted")
    }

    mutating func observe(_ event: SemanticEvent) {
        count(registry.onSemanticEvent(event))
    }

    mutating func observe(gmcp message: GMCPMessage) {
        count(registry.onGMCP(package: message.package, json: message.json))
    }

    private mutating func count(_ effects: [ScriptEffect]) {
        for effect in effects {
            if case .playSound(let file, _, _) = effect { counts[file, default: 0] += 1 }
        }
    }
}

extension CorpusReplay {
    static var cueBaselineDirectory: URL {
        realHome.appendingPathComponent(
            "Documents/Proteles/Diagnostics/replay-cue-baseline",
            isDirectory: true
        )
    }

    static func loadCueBaseline(
        named name: String,
        from directory: URL = cueBaselineDirectory
    ) -> [String: Int]? {
        let url = directory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: Int].self, from: data)
    }

    static func saveCueBaseline(
        _ counts: [String: Int], named name: String, to directory: URL = cueBaselineDirectory
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(counts).write(to: directory.appendingPathComponent("\(name).json"))
    }

    /// Compare a session's cues to its pin (pinning on first sight or under
    /// `PROTELES_REPLAY_PIN`). Returns a report when they differ, else nil.
    static func checkCues(_ replayed: Replayed) throws -> String? {
        let name = replayed.session.name
        guard let baseline = loadCueBaseline(named: name), !shouldPin else {
            try saveCueBaseline(replayed.cues, named: name)
            return nil
        }
        return describeCueDiff(name: name, baseline: baseline, current: replayed.cues)
    }

    /// `name: cue file before → after` for every file whose count moved.
    static func describeCueDiff(name: String, baseline: [String: Int], current: [String: Int]) -> String? {
        let files = Set(baseline.keys).union(current.keys).sorted()
        let moved = files.filter { baseline[$0, default: 0] != current[$0, default: 0] }
        guard !moved.isEmpty else { return nil }
        let lines = moved.map { "  \($0): \(baseline[$0, default: 0]) → \(current[$0, default: 0])" }
        return "\(name): cues differ\n" + lines.joined(separator: "\n")
    }
}
