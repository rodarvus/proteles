import Foundation

/// Reads a recording produced by ``SessionRecorder`` and exposes its
/// chunks for replay through a ``LinePipeline`` or directly into a
/// test scope.
///
/// `SessionReplayer` is a value type — load the file once, then call
/// ``chunks()`` to iterate. The replayer doesn't pace replay against
/// the original timestamps; tests want as-fast-as-possible. Callers
/// that want real-time replay can compare adjacent timestamps and
/// sleep between iterations themselves.
public struct SessionReplayer: Sendable {
    /// Errors surfaced to callers.
    public enum ReplayerError: Error, Equatable {
        case openFailed(String)
        case parseFailed(line: Int, description: String)
    }

    public let url: URL
    public let chunks: [SessionRecording.Chunk]

    /// Open and fully parse `url`. The whole recording lives in memory
    /// once parsed — fine for test fixtures (typical sizes are
    /// megabytes at worst); real long-form session logs use a
    /// different access pattern (FTS search via ``ScrollbackDatabase``).
    public init(url: URL) throws {
        self.url = url

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ReplayerError.openFailed(error.localizedDescription)
        }

        let decoder = JSONDecoder()
        var parsed: [SessionRecording.Chunk] = []
        // JSONL: one JSON object per line. Empty lines are tolerated.
        // Splitting on `\n` rather than using a Scanner keeps things
        // dependency-free; recordings are not huge.
        let raw = String(decoding: data, as: UTF8.self)
        var lineNumber = 0
        for line in raw.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let chunkData = Data(trimmed.utf8)
            do {
                let chunk = try decoder.decode(
                    SessionRecording.Chunk.self,
                    from: chunkData
                )
                parsed.append(chunk)
            } catch {
                throw ReplayerError.parseFailed(
                    line: lineNumber,
                    description: error.localizedDescription
                )
            }
        }
        chunks = parsed
    }

    /// Total bytes across all chunks. Useful for progress reporting.
    public var totalByteCount: Int {
        chunks.reduce(0) { $0 + $1.bytes.count }
    }

    /// Wall-clock duration the recording spans (last timestamp minus
    /// first), or zero if empty / single-chunk.
    public var duration: TimeInterval {
        guard let first = chunks.first?.timestamp,
              let last = chunks.last?.timestamp
        else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// Replay every chunk through `pipeline`, collecting all emitted
    /// `Line`s and any negotiation responses the pipeline produced.
    /// `pipeline.flush()` is called once at the end so a trailing
    /// partial line is not silently lost.
    public func replay(
        into pipeline: inout LinePipeline
    ) throws -> ReplayOutput {
        var result = ReplayOutput()
        for chunk in chunks {
            let output = try pipeline.consume(Array(chunk.bytes))
            result.lines.append(contentsOf: output.lines)
            result.responses.append(contentsOf: output.responses)
            if output.activatedCompression {
                result.compressionActivations += 1
            }
        }
        let trailing = pipeline.flush()
        result.lines.append(contentsOf: trailing)
        return result
    }

    /// Aggregate output across an entire replay.
    public struct ReplayOutput: Sendable, Equatable {
        public var lines: [Line] = []
        public var responses: [[UInt8]] = []
        public var compressionActivations: Int = 0
    }
}
