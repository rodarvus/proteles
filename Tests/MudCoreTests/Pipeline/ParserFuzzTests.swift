import Foundation
@testable import MudCore
import Testing

/// Robustness fuzzing for the wire-parsing pipeline (#26). Feeds large volumes
/// of arbitrary + adversarial bytes through `LinePipeline.consume` (which drives
/// the telnet, ANSI, GMCP and MCCP2 state machines) and asserts it never traps,
/// hangs, or produces unbounded output. Garbage may legitimately *throw* (e.g.
/// MCCP2 inflate of non-zlib data) — that's fine; a *trap* would crash the test
/// process and fail the run.
@Suite("Parser fuzzing — pipeline robustness (#26)")
struct ParserFuzzTests {
    /// Deterministic xorshift64* PRNG, so any failure reproduces from its seed
    /// (and the suite doesn't use the banned nondeterministic randomness).
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 0x2545_F491_4F6C_DD1D
        }
    }

    /// Bytes biased toward protocol-significant values (IAC verbs, ESC/CSI, GMCP
    /// option + punctuation) so the fuzz actually drives the state machines
    /// rather than mostly-printable noise.
    private static let salientBytes: [UInt8] = [
        0xFF, 0xFA, 0xF0, 0xFB, 0xFC, 0xFD, 0xFE, // IAC, SB, SE, WILL/WONT/DO/DONT
        0x1B, 0x5B, 0x6D, // ESC, '[', 'm'
        0xC9, 0x55, 0x56, // GMCP (201), MCCP1 (85), MCCP2 (86)
        0x00, 0x0A, 0x0D, // NUL, LF, CR
        UInt8(ascii: ";"), UInt8(ascii: "{"), UInt8(ascii: "}"),
        UInt8(ascii: "\""), UInt8(ascii: "["), UInt8(ascii: ".")
    ]

    private func fuzzByte(_ rng: inout SeededRNG) -> UInt8 {
        if Bool.random(using: &rng) {
            return Self.salientBytes[Int.random(in: 0..<Self.salientBytes.count, using: &rng)]
        }
        return UInt8.random(in: 0...255, using: &rng)
    }

    @Test("consume never traps on arbitrary wire bytes (fed in random chunks)")
    func pipelineFuzz() {
        var rng = SeededRNG(seed: 0xF0F0_1234_ABCD_0001)
        for _ in 0..<4000 {
            var pipeline = LinePipeline()
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                let length = Int.random(in: 0...400, using: &rng)
                let bytes = (0..<length).map { _ in fuzzByte(&rng) }
                if let output = try? pipeline.consume(bytes) {
                    #expect(output.lines.count < 100_000) // runaway guard
                }
            }
        }
    }

    @Test("truncated / malformed / oversized sequences are handled, not trapped")
    func adversarialSequences() {
        let cases: [[UInt8]] = [
            [0x1B], // bare ESC
            [0x1B, 0x5B], // CSI with no params/final
            [0x1B, 0x5B] + Array("99999999999999999999".utf8) + [0x6D], // overflowing SGR param
            [0x1B, 0x5B] + Array(repeating: UInt8(ascii: ";"), count: 64) + [0x6D], // many empty params
            [0x1B, 0x5B] + Array("38;5;".utf8), // truncated 256-colour
            [0xFF], // bare IAC
            [0xFF, 0xFA], // IAC SB, nothing more
            [0xFF, 0xFA, 0xC9], // IAC SB GMCP, never closed
            [0xFF, 0xFA, 0xC9] + Array("Char.Vitals {bad json,,".utf8) + [0xFF, 0xF0], // bad GMCP json
            [0xFF, 0xFA, 0xC9] + Array(repeating: 0x41, count: 5000) + [0xFF, 0xF0], // huge subneg
            [0xFF, 0xFB], [0xFF, 0xFD, 0x56], [0xFF, 0xFC], // partial negotiations
            Array(repeating: 0x1B, count: 2000), // ESC storm
            Array(repeating: 0xFF, count: 2000) // IAC storm
        ]
        for bytes in cases {
            var pipeline = LinePipeline()
            _ = try? pipeline.consume(bytes) // must not trap
        }

        // The same bytes split one-per-consume must be just as safe (state
        // carried across calls is where boundary bugs hide).
        var split = LinePipeline()
        let stream = [0x1B, 0x5B, 0x33, 0x31, 0x6D] + Array("hello".utf8)
            + [0xFF, 0xFA, 0xC9] + Array("X".utf8) + [0xFF, 0xF0, 0x0A]
        for byte in stream {
            _ = try? split.consume([UInt8(byte)])
        }
    }
}
