import Foundation
import Logging

/// The mapper's system-note stream + write-failure surfacing (its own file
/// for ``Mapper``'s length budget). Notes are one-off messages outside the
/// GMCP flow (delayed cexit results, persistence warnings); the session
/// drains the stream and echoes each to the output view.
extension Mapper {
    /// Subscribe to mapper system notes. The session drains this and echoes
    /// each note; no backfill.
    public func subscribeNotes() -> AsyncStream<String> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        noteSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNoteSubscriber(id) }
        }
        return stream
    }

    private func removeNoteSubscriber(_ id: UUID) {
        noteSubscribers[id] = nil
    }

    /// Run one map-DB write, surfacing failure instead of swallowing it:
    /// logged always; the first per session also notes to the output so the
    /// user learns their map stopped persisting (the live map keeps working).
    /// (2026-06 audit: `try?` on the upserts let the in-memory graph silently
    /// diverge from Aardwolf.db, so rooms "vanished" next launch, hint-free.)
    func persist(_ what: String, _ write: () throws -> Void) {
        do {
            try write()
        } catch {
            logger.error("map database write failed (\(what)): \(error)")
            guard !reportedWriteFailure else { return }
            reportedWriteFailure = true
            for continuation in noteSubscribers.values {
                continuation.yield(
                    "Mapper: writing to the map database failed (\(what)). The live map keeps "
                        + "working, but changes may not survive a restart; further failures are "
                        + "logged silently."
                )
            }
        }
    }
}
