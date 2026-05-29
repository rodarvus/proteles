import Foundation

/// Pure policy for pruning old session logs (PLAN.md §7 logging follow-up).
/// Session-log filenames embed a sortable timestamp (`session-YYYY-MM-DD-HHmmss`),
/// so "newest" is just the lexicographically-largest name — no filesystem dates
/// needed, which keeps this unit-testable.
public enum LogRetention {
    /// The files to delete so only the newest `keep` remain. Returns nothing
    /// when at or under the limit (or `keep <= 0` would delete all — guarded to
    /// "keep everything" so a misconfigured 0 can't wipe the folder).
    public static func filesToPrune(_ files: [URL], keeping keep: Int) -> [URL] {
        guard keep > 0, files.count > keep else { return [] }
        let newestFirst = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        return Array(newestFirst.dropFirst(keep))
    }
}
