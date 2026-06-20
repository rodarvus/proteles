import Foundation

/// Shared helpers for the end-to-end session suites (the 2026-06 audit found
/// these duplicated verbatim per file).
enum SessionTestSupport {
    /// Frame a GMCP message as Aardwolf sends it (IAC SB 201 <payload> IAC SE).
    static func gmcpBytes(_ payload: String) -> [UInt8] {
        [255, 250, 201] + Array(payload.utf8) + [255, 240]
    }

    /// Poll until `check` passes or ~8s elapses (400 × 20ms). Returns the final
    /// check result, so a timeout still reports the real state. The budget is
    /// generous because these conditions usually wait on the SessionController
    /// async timer loop, which is starved under CI load (#26) — it returns the
    /// instant the condition holds, so a passing test pays no extra time.
    static func poll(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await check()
    }
}
