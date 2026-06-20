import Foundation

/// Locates source-line context for a Lua error report — the "context" half of
/// the native traceback feature (the native equivalent of Sath's
/// `traceback_context`). Given a Lua error/traceback it finds the topmost frame
/// in a chunk we have source for; given that source + line it returns the
/// surrounding lines (the runtime colours them). Pure + testable.
enum LuaSourceContext {
    /// One line of a source-context window.
    struct WindowLine: Equatable {
        let number: Int
        let text: String
        let isError: Bool
    }

    /// The topmost `<chunk>:<line>` reference in a Lua error/traceback whose
    /// chunk is one we have source for. Frames are innermost-first (the error
    /// location, then the stack), so the first hit is the failing line. Our
    /// chunk names (plugin ids, module names) carry no spaces/colons, and a frame
    /// puts the chunk at the start (after the leading tab), so an exact prefix
    /// match is unambiguous — it won't fire on `[string "…"]` or `[C]` frames.
    static func topFrame(in message: String, knownChunks: Set<String>) -> (chunk: String, line: Int)? {
        for rawLine in message.split(separator: "\n") {
            let trimmed = rawLine.drop { $0 == " " || $0 == "\t" }
            for chunk in knownChunks where trimmed.hasPrefix(chunk + ":") {
                let digits = trimmed.dropFirst(chunk.count + 1).prefix { $0.isNumber }
                if let line = Int(digits) { return (chunk, line) }
            }
        }
        return nil
    }

    /// The lines around `line` (±`radius`, clamped to the file), each tagged
    /// whether it is the offending line. Nil if `line` is out of range. The
    /// default radius (5) matches Sath's `traceback_context` window.
    static func window(source: String, line: Int, radius: Int = 5) -> [WindowLine]? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 1, line <= lines.count else { return nil }
        let lower = max(1, line - radius)
        let upper = min(lines.count, line + radius)
        return (lower...upper).map { number in
            WindowLine(number: number, text: String(lines[number - 1]), isError: number == line)
        }
    }
}
