import Foundation

/// Append-only JSONL ring of the most recent scrollback lines — the
/// crash-safety **hot path** of the #66 persistence redesign.
///
/// The 2026-06-12 session triggered an OS disk-writes exception: 2.15 GB
/// dirtied in 6.6 h, ~40× the content size, 82% of it attributed to
/// `ScrollbackPersistence`'s 250 ms SQLite commits — every tiny transaction
/// rewrites WAL pages for the row b-tree *and* the FTS5 term trees, and the
/// amplification grows with the (211 MB, append-forever) database. The
/// redesign splits the jobs: per-line durability lands **here** (appending
/// to a flat file dirties one page per flush), while SQLite/FTS indexing
/// becomes a cold path of large, infrequent transactions
/// (``ScrollbackPersistence``).
///
/// Ring semantics: entries append with a monotonically increasing `seq`
/// (persisted across launches); when the file exceeds 2× ``targetLines``
/// it is atomically rewritten keeping the newest ``targetLines`` — so the
/// file stays small and the rewrite cost amortises to ~2× content.
///
/// Not `Sendable`: owned and driven by the ``ScrollbackPersistence`` actor,
/// like `Inflater` under `SessionController`.
public final class ScrollbackSidecar {
    /// One persisted line + its ring sequence number.
    public struct Entry: Codable, Equatable, Sendable {
        public let seq: UInt64
        public let timestamp: Date
        public let text: String
        public let runsJSON: String?

        enum CodingKeys: String, CodingKey {
            case seq
            case timestamp
            case text
            case runsJSON = "runs_json"
        }

        /// Reconstruct the styled ``Line`` (placeholder id — stores assign
        /// their own on append/restore).
        public func toLine() throws -> Line {
            let runs: [StyledRun] = if let runsJSON, !runsJSON.isEmpty {
                try JSONDecoder().decode([StyledRun].self, from: Data(runsJSON.utf8))
            } else {
                []
            }
            return Line(id: LineID(0), timestamp: timestamp, text: text, runs: runs)
        }
    }

    public let url: URL
    public let targetLines: Int
    /// The next sequence number to assign (continues across launches).
    private var nextSeq: UInt64

    private var entryCount: Int
    private let encoder = JSONEncoder()

    /// Open (or create) the sidecar at `url`, continuing the sequence from
    /// the existing content. A torn/corrupt trailing line (mid-write crash)
    /// is skipped — every complete line stands alone.
    public init(url: URL, targetLines: Int = 1000) {
        self.url = url
        self.targetLines = max(1, targetLines)
        let existing = Self.decode(url: url)
        entryCount = existing.count
        nextSeq = (existing.last?.seq).map { $0 + 1 } ?? 0
    }

    /// `State/scrollback-tail.jsonl`.
    public static func defaultURL() throws -> URL {
        try ProtelesPaths.stateDirectory().appendingPathComponent("scrollback-tail.jsonl")
    }

    // MARK: - Writes

    /// Append a batch of lines; returns the entries written (with their
    /// assigned sequence numbers). One file append + flush per batch — the
    /// whole point: O(content) bytes, one dirtied page per flush.
    @discardableResult
    public func append(_ lines: [Line]) throws -> [Entry] {
        guard !lines.isEmpty else { return [] }
        var entries: [Entry] = []
        var payload = Data()
        for line in lines {
            let runsJSON: String? = if line.runs.isEmpty {
                nil
            } else {
                try String(decoding: encoder.encode(line.runs), as: UTF8.self)
            }
            let entry = Entry(
                seq: nextSeq, timestamp: line.timestamp, text: line.text, runsJSON: runsJSON
            )
            try payload.append(encoder.encode(entry))
            payload.append(0x0A)
            entries.append(entry)
            nextSeq += 1
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
            entryCount = 0
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
        entryCount += entries.count
        if entryCount > targetLines * 2 {
            try rotate()
        }
        return entries
    }

    // MARK: - Reads

    /// The newest `limit` entries, oldest-first.
    public func tail(limit: Int) -> [Entry] {
        let all = Self.decode(url: url)
        return Array(all.suffix(max(0, limit)))
    }

    // MARK: - Private

    /// Atomic rewrite keeping the newest ``targetLines`` entries.
    private func rotate() throws {
        let keep = Self.decode(url: url).suffix(targetLines)
        var payload = Data()
        for entry in keep {
            try payload.append(encoder.encode(entry))
            payload.append(0x0A)
        }
        try payload.write(to: url, options: .atomic)
        entryCount = keep.count
    }

    private static func decode(url: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(Entry.self, from: $0)
        }
    }
}
