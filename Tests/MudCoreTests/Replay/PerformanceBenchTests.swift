import Foundation
import GRDB
@testable import MudCore
import Testing

/// #59 measurement harness — NOT part of the normal suite. Run with:
///
///     PROTELES_BENCH=1 swift test --filter PerformanceBench
///
/// Replays a real recorded session (the largest `.jsonl` under
/// `~/Documents/Proteles/Recordings/`) and the live mapper DB to answer
/// the audit's B-items with numbers instead of theory:
///
/// - **B1** SoundEventClassifier.events(forLine:) — the 48-regex sweep an
///   unmuted soundpack pays per displayed line.
/// - **B3** Mapper.find()'s linear room-name scan vs the `rooms_lookup`
///   FTS table the imported Aardwolf.db already carries.
/// - **B4** the gag-reason string built per gagged line even when
///   transcript logging is off.
///
/// B2 (S&D shim-state probe) and B5 (output view) can't be measured
/// honestly off the live app; they get os_signpost markers instead and an
/// Instruments pass on a live combat session.
@Suite("PerformanceBench (#59)", .serialized, .enabled(if: benchEnabled))
struct PerformanceBenchTests {
    @Test("B1: classifier cost per line over a real session")
    func b1ClassifierCost() throws {
        let lines = try replayLargestRecording()
        try #require(!lines.isEmpty, "no recordings to replay")

        // Warm the regex cache, then measure several passes.
        for line in lines.prefix(500) {
            _ = SoundEventClassifier.events(forLine: line.text)
        }
        let passes = 5
        let clock = ContinuousClock()
        var fired = 0
        let elapsed = clock.measure {
            for _ in 0..<passes {
                for line in lines {
                    fired += SoundEventClassifier.events(forLine: line.text).count
                }
            }
        }
        let perLine = elapsed / (passes * lines.count)
        print("BENCH B1: \(lines.count) lines × \(passes) passes, \(fired) events fired")
        print("BENCH B1: \(perLine) per line; at 100 lines/s = \(perLine * 100) per second of combat")
    }

    @Test("B3: linear room-name scan vs rooms_lookup FTS on the live DB")
    func b3FindScanVsFTS() throws {
        let dbURL = realHome()
            .appendingPathComponent("Documents/Proteles/Databases/Aardwolf.db")
        try #require(
            FileManager.default.fileExists(atPath: dbURL.path), "no live Aardwolf.db"
        )
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)

        // The in-memory shape Mapper.find() scans: every (uid, name).
        let rooms: [(uid: String, name: String)] = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT uid, name FROM rooms").map {
                (uid: $0["uid"] ?? "", name: $0["name"] ?? "")
            }
        }
        let queries = ["inn", "temple", "the dragon", "fountain square", "zzzznothing"]
        let clock = ContinuousClock()

        var scanHits = 0
        let scan = clock.measure {
            for query in queries {
                let needle = query.lowercased()
                scanHits += rooms.count { $0.name.lowercased().contains(needle) }
            }
        }

        var ftsHits = 0
        let fts = try queue.read { db in
            clock.measure {
                for query in queries {
                    let sql = "SELECT uid FROM rooms_lookup WHERE name MATCH ?"
                    ftsHits += (try? Row.fetchAll(db, sql: sql, arguments: [query]).count) ?? 0
                }
            }
        }
        print("BENCH B3: \(rooms.count) rooms, \(queries.count) queries")
        print("BENCH B3: linear scan \(scan) (\(scanHits) hits) vs FTS \(fts) (\(ftsHits) hits)")
        print("BENCH B3: per-find scan \(scan / queries.count) vs FTS \(fts / queries.count)")
    }

    @Test("B4: gag-reason string construction cost")
    func b4GagReasonCost() throws {
        let lines = try replayLargestRecording()
        try #require(!lines.isEmpty, "no recordings to replay")
        let clock = ContinuousClock()
        let passes = 5
        var sink = 0
        // The exact construction SessionController+Scripting does per gagged
        // line (interpolation included), with representative flag values.
        let elapsed = clock.measure {
            for _ in 0..<passes {
                for line in lines {
                    let reasons = [
                        true ? "script" : nil,
                        false ? "snd" : nil,
                        false ? "richexits" : nil,
                        true ? "blank" : nil,
                        false ? "wishprobe" : nil,
                        false ? "tag" : nil
                    ].compactMap(\.self).joined(separator: "+")
                    sink += "[\(reasons)] \(line.text)".count
                }
            }
        }
        let perLine = elapsed / (passes * lines.count)
        print("BENCH B4: \(perLine) per gagged line (sink \(sink))")
        print("BENCH B4: at 100 gagged lines/s = \(perLine * 100) per second")
    }
}

/// Env gate so the normal suite (and CI) never pays for the bench.
private var benchEnabled: Bool {
    ProcessInfo.processInfo.environment["PROTELES_BENCH"] != nil
}

/// The user's actual home — NOT ProtelesPaths, which redirects to a temp
/// sandbox under the test runner (#45). Read-only access to real data.
private func realHome() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
}

/// Replay the largest recording's bytes through a LinePipeline and return
/// the rendered lines (what onLine/the classifier actually sees).
private func replayLargestRecording() throws -> [Line] {
    let recordings = realHome().appendingPathComponent("Documents/Proteles/Recordings")
    let jsonls = (try? FileManager.default.contentsOfDirectory(
        at: recordings, includingPropertiesForKeys: [.fileSizeKey]
    ))?.filter { $0.pathExtension == "jsonl" } ?? []
    let largest = jsonls.max { lhs, rhs in
        let left = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let right = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return left < right
    }
    guard let largest else { return [] }
    let replayer = try SessionReplayer(url: largest)
    var pipeline = LinePipeline()
    let output = try replayer.replay(into: &pipeline)
    print("BENCH: replayed \(largest.lastPathComponent): \(output.lines.count) lines, "
        + "\(replayer.totalByteCount) bytes, \(Int(replayer.duration))s of session")
    return output.lines
}
