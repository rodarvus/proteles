import Foundation
@testable import MudCore
import Testing

/// Parser robustness + throughput sanity for CI (#26).
///
/// The fuzz passes are **deterministic** (a seeded SplitMix64, fixed seeds),
/// so a CI failure reproduces locally byte-for-byte. The contract under fuzz
/// is "never crash, never hang, always flushable" — throwing on garbage is
/// acceptable behaviour (a real session surfaces it and disconnects), dying
/// is not. The throughput test is a *sanity floor* with ~100× headroom, not
/// a perf gate: shared CI runners vary wildly, but a catastrophic regression
/// (accidentally quadratic line assembly, runaway regex) still trips it.
@Suite("LinePipeline fuzz + throughput sanity (#26)")
struct LinePipelineFuzzTests {
    /// Deterministic 64-bit generator (SplitMix64) — Foundation's
    /// SystemRandomNumberGenerator is seedless, useless for reproducible fuzz.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test("random byte soup never crashes or hangs the pipeline", arguments: [
        UInt64(1), 42, 0xDEAD_BEEF, 0x5EED_5EED_5EED_5EED
    ])
    func randomByteSoup(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        var pipeline = LinePipeline()
        var produced = 0
        for _ in 0..<200 {
            let size = Int.random(in: 1...4096, using: &rng)
            let chunk = (0..<size).map { _ in UInt8.random(in: 0...255, using: &rng) }
            do {
                produced += try pipeline.consume(chunk).lines.count
            } catch {
                // Garbage may legitimately throw (e.g. a byte pattern that
                // activates MCCP2 then fails to inflate) — a real session
                // disconnects; the fuzz contract is just no-crash/no-hang.
                pipeline = LinePipeline()
            }
        }
        _ = pipeline.flush()
        #expect(produced >= 0) // the assertion is "we got here alive"
    }

    @Test("telnet/ANSI edge-case corpus never crashes the pipeline")
    func nastyCorpus() {
        let iac: UInt8 = 255
        let corpus: [[UInt8]] = [
            [iac], // dangling IAC at chunk end
            [iac, 250, 201], // IAC SB GMCP, never terminated
            [iac, 250], // IAC SB cut before the option byte
            [iac, 251], // WILL cut before the option byte
            Array("line with no newline ".utf8) + [0xC3], // UTF-8 cut mid-sequence
            [0xC3, 0x28], // invalid UTF-8 continuation
            Array("\u{1B}[".utf8), // ANSI CSI cut at chunk end
            Array("\u{1B}[38;5;".utf8), // 256-colour sequence cut mid-args
            Array("\u{1B}]0;title".utf8), // OSC, never terminated
            [0x00, 0x00, 0x07, 0x08], // NULs + BEL + BS
            Array(repeating: UInt8(ascii: "x"), count: 100_000), // one huge unterminated line
            [iac, iac], // escaped literal 0xFF
            Array("a\r".utf8), Array("\nb\r\n".utf8) // CRLF split across chunks
        ]
        var pipeline = LinePipeline()
        for chunk in corpus {
            do {
                _ = try pipeline.consume(chunk)
            } catch {
                pipeline = LinePipeline()
            }
        }
        _ = pipeline.flush()
    }

    @Test("throughput sanity: the welcome banner replays at >2k lines/s")
    func throughputFloor() throws {
        guard let url = Bundle.module.url(
            forResource: "Fixtures/aardwolf-welcome-banner", withExtension: "jsonl"
        ) else {
            Issue.record("fixture missing")
            return
        }
        let replayer = try SessionReplayer(url: url)
        let reps = 200
        var lines = 0
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for _ in 0..<reps {
                // Fresh pipeline per rep — the fixture activates MCCP2, so its
                // chunks only decode against a fresh compression stream.
                var pipeline = LinePipeline()
                lines += try replayer.replay(into: &pipeline).lines.count
            }
        }
        let perSecond = Double(lines) / max(elapsed.timeInterval, 0.001)
        // Real hardware does hundreds of thousands of lines/s; the floor only
        // catches catastrophic regressions, immune to runner variance.
        #expect(perSecond > 2000, "pipeline throughput collapsed: \(Int(perSecond)) lines/s")
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
