import Foundation

/// Appends ``SessionRecording/Chunk`` records to a JSONL file as bytes
/// arrive.
///
/// The recorder is **append-only** and stream-friendly: every call to
/// ``record(_:timestamp:)`` writes one line and flushes. There's no
/// in-memory buffering beyond what the OS layers do for `FileHandle`,
/// so a crash mid-session loses at most the trailing partial write.
///
/// Threading: the recorder is a class, but every public method
/// serialises through an internal `os_unfair_lock`-equivalent — fine
/// for the call rates we see (one chunk per network read, which is
/// firmly milliseconds-apart even in bursts). Most callers will own
/// one recorder per session and feed it from a single Task, so
/// contention is effectively zero.
public final class SessionRecorder: @unchecked Sendable {
    /// Errors surfaced to callers.
    public enum RecorderError: Error, Equatable {
        case openFailed(String)
        case writeFailed(String)
    }

    /// On-disk path of the recording.
    public let url: URL

    private let fileHandle: FileHandle
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private var isClosed = false

    /// Open `url` for appending. Creates the file (and any missing
    /// parent directories) if needed.
    public init(url: URL) throws {
        self.url = url

        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecorderError.openFailed(error.localizedDescription)
        }

        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        do {
            fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.seekToEnd()
        } catch {
            throw RecorderError.openFailed(error.localizedDescription)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
    }

    deinit {
        try? fileHandle.close()
    }

    /// Append one chunk to the recording. Returns synchronously after
    /// the write completes.
    public func record(_ bytes: [UInt8], timestamp: Date = Date()) throws {
        let chunk = SessionRecording.Chunk(
            timestamp: timestamp,
            bytes: Data(bytes)
        )
        let data: Data
        do {
            data = try encoder.encode(chunk)
        } catch {
            throw RecorderError.writeFailed(error.localizedDescription)
        }

        lock.withLock {
            guard !isClosed else { return }
            do {
                try fileHandle.write(contentsOf: data)
                try fileHandle.write(contentsOf: Data([0x0A]))
            } catch {
                // No exception escape — recording is best-effort. If
                // we can't write we set closed so subsequent calls
                // become no-ops, avoiding a death spiral of failed
                // writes on every chunk.
                isClosed = true
            }
        }
    }

    /// Close the file. Subsequent ``record(_:timestamp:)`` calls are
    /// no-ops; safe to call multiple times.
    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            try? fileHandle.synchronize()
            try? fileHandle.close()
            isClosed = true
        }
    }
}
