import Foundation

/// Shared helpers for the end-to-end session suites (the 2026-06 audit found
/// these duplicated verbatim per file).
enum SessionTestSupport {
    /// Frame a GMCP message as Aardwolf sends it (IAC SB 201 <payload> IAC SE).
    static func gmcpBytes(_ payload: String) -> [UInt8] {
        [255, 250, 201] + Array(payload.utf8) + [255, 240]
    }

    /// Poll until `check` passes or ~2s elapses (100 × 20ms). Returns the
    /// final check result, so a timeout still reports the real state.
    static func poll(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await check() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await check()
    }
}
