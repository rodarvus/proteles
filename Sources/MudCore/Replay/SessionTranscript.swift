import Foundation

/// A human-readable, timestamped session transcript — the *debugging*
/// companion to ``SessionRecorder``.
///
/// ``SessionRecorder`` captures raw inbound **wire bytes** (base64 JSONL) so a
/// replay can re-run the full protocol stack deterministically. That format is
/// great for replay but useless for eyeballing what actually happened —
/// especially for **local** events (typed commands, alias/trigger sends,
/// script `Note`/echo output, GMCP) which never appear in the wire capture at
/// all, because the recorder only sees what the *server* sent.
///
/// This writer fills that gap. It emits one plain-text line per event:
///
///     2026-05-25T19:40:01.123Z RECV  You are standing in a field.
///     2026-05-25T19:40:01.130Z GMCP  char.status {"state":3,"level":201}
///     2026-05-25T19:40:01.200Z SEND  cp info
///     2026-05-25T19:40:01.205Z INPUT cp
///     2026-05-25T19:40:01.300Z NOTE  [SnD-DBG] do_cp_check clk=1748196001.298
///
/// Categories let a reader (or grep) separate MUD output (`RECV`), commands
/// sent to the MUD (`SEND`), the user's raw typed input before alias expansion
/// (`INPUT`), local script/echo output (`NOTE`), and GMCP packets (`GMCP`).
/// Timestamps are **local-time** ISO-8601 with millisecond precision (the zone
/// offset is included, e.g. `+01:00`/`Z`), so they match the user's wall clock —
/// while still being precise enough to see, for example, whether two
/// `do_cp_check` calls fall inside S&D's 1-second debounce window.
///
/// Like ``SessionRecorder`` it is append-only, thread-safe (one `NSLock`),
/// best-effort (write failures silence further writes rather than throw), and
/// written next to the binary recording (`session-….log` beside
/// `session-….jsonl`). Writes are queued onto a private serial writer so a
/// slow filesystem cannot block live session processing.
public final class SessionTranscript: @unchecked Sendable {
    /// The kind of event a transcript line records.
    public enum Category: String, Sendable {
        /// A line received from the MUD (post-telnet-parse, pre-gag).
        case recv = "RECV"
        /// Text sent to the MUD (alias/trigger sends, autologin, etc.).
        case send = "SEND"
        /// A command the user typed, before alias expansion.
        case input = "INPUT"
        /// Local output produced by a script/echo/note (never sent or received).
        case note = "NOTE"
        /// A GMCP packet (`package` + JSON), as dispatched.
        case gmcp = "GMCP"
        /// A line withheld from the main output (a trigger/S&D/Rich-Exits/blank
        /// gag). Logged with its reason so a recording shows *what* was gagged,
        /// not just what arrived — `recv` is pre-gag, so it can't reveal that.
        case gag = "GAG"
    }

    /// On-disk path of the transcript.
    public let url: URL

    private let fileHandle: FileHandle
    private let writerQueue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false
    private let timestampFormatter: TranscriptTimestampFormatter

    /// Open `url` for appending. Creates the file (and any missing parent
    /// directories) if needed.
    public init(url: URL) throws {
        self.url = url

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SessionRecorder.RecorderError.openFailed(error.localizedDescription)
        }

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        do {
            fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.seekToEnd()
        } catch {
            throw SessionRecorder.RecorderError.openFailed(error.localizedDescription)
        }
        writerQueue = DispatchQueue(
            label: "com.proteles.session-transcript",
            qos: .utility
        )

        timestampFormatter = TranscriptTimestampFormatter()
    }

    deinit {
        close()
    }

    /// Append one event. Embedded newlines/carriage returns in `text` are
    /// escaped so each event stays on a single line (grep-friendly).
    public func log(_ category: Category, _ text: String, timestamp: Date = Date()) {
        lock.withLock {
            guard !isClosed else { return }
            writerQueue.async { [fileHandle, timestampFormatter] in
                PerformanceProbe.shared.measure(
                    "transcript.write",
                    events: 1,
                    thresholdMS: 100
                ) {
                    Self.write(
                        category,
                        text,
                        timestamp: timestamp,
                        formatter: timestampFormatter,
                        fileHandle: fileHandle
                    )
                }
            }
        }
    }

    private static func write(
        _ category: Category,
        _ text: String,
        timestamp: Date,
        formatter: TranscriptTimestampFormatter,
        fileHandle: FileHandle
    ) {
        do {
            let stamp = formatter.string(from: timestamp)
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            let tag = category.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0)
            let line = "\(stamp) \(tag) \(escaped)\n"
            guard let data = line.data(using: .utf8) else { return }
            try fileHandle.write(contentsOf: data)
        } catch {
            // Best-effort transcript: write failures are intentionally ignored.
        }
    }

    /// Close the file. Subsequent ``log(_:_:timestamp:)`` calls are no-ops;
    /// safe to call multiple times.
    public func close() {
        let shouldClose = lock.withLock {
            if isClosed { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        writerQueue.sync {
            try? fileHandle.synchronize()
            try? fileHandle.close()
        }
    }

    /// The transcript path that pairs with a binary recording `url`: same
    /// directory and stem, `.log` extension instead of `.jsonl`.
    public static func url(pairedWith recordingURL: URL) -> URL {
        recordingURL.deletingPathExtension().appendingPathExtension("log")
    }
}

private final class TranscriptTimestampFormatter: @unchecked Sendable {
    private let formatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Local time (with offset) so timestamps match the user's wall clock; a
        // non-UTC zone makes `.withInternetDateTime` emit `+HH:MM` instead of `Z`.
        formatter.timeZone = TimeZone.current
        self.formatter = formatter
    }

    func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
