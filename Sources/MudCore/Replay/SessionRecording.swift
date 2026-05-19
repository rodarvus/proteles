import Foundation

/// File format for recorded MUD sessions (PLAN.md §8.3 replay
/// harness).
///
/// The on-disk representation is **JSONL**: one JSON object per line,
/// each describing a single byte chunk as the network actually
/// delivered it. Format:
///
///     {"t":1700000000.123,"b":"BASE64..."}
///
/// Why JSONL:
///   - Stream-writable: append a line per chunk; no need to know the
///     final count in advance.
///   - Stream-readable: scan one line at a time during replay.
///   - Human-inspectable: pop open a fixture in any editor and read
///     timestamps + base64 chunks without bespoke tooling.
///   - Compact-enough: base64 overhead is ~33%, but recordings live
///     in `fixtures/` and aren't shipped, so the size hit doesn't
///     matter.
///
/// The recorded bytes are the **wire** bytes — pre-MCCP2-decompression,
/// pre-Telnet-parsing. That makes the recording a faithful capture of
/// what `NetworkConnection.bytes` delivered, and means a replay
/// through ``LinePipeline`` exercises the full protocol stack
/// (compression handshake included).
public enum SessionRecording {
    /// One captured chunk: an absolute timestamp (Unix seconds, double
    /// precision) and the raw bytes that arrived together.
    ///
    /// On-disk shape per JSONL line:
    ///
    ///     {"timestamp":1700000000.123,"bytes":"BASE64..."}
    public struct Chunk: Codable, Equatable, Sendable {
        public let timestamp: Date
        public let bytes: Data

        public init(timestamp: Date, bytes: Data) {
            self.timestamp = timestamp
            self.bytes = bytes
        }

        /// Custom encoding: timestamp as Unix seconds (`Double`) rather
        /// than the default Codable Date strategy, which encodes
        /// reference dates and makes inspection annoying.
        enum CodingKeys: String, CodingKey {
            case timestamp
            case bytes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let seconds = try container.decode(Double.self, forKey: .timestamp)
            timestamp = Date(timeIntervalSince1970: seconds)
            bytes = try container.decode(Data.self, forKey: .bytes)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
            try container.encode(bytes, forKey: .bytes)
        }
    }
}
