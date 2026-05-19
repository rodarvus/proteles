import CZlib
import Foundation

/// Streaming zlib compressor.
///
/// Phase-2 MudCore does not *send* compressed data — Aardwolf only
/// negotiates inbound compression via MCCP2, and MCCP3 (bidirectional)
/// is out of scope. This type exists so tests can produce valid
/// zlib-format compressed payloads matching what a real MCCP2 server
/// would emit, without having to commit fixture bytes to disk.
///
/// Not Sendable; same rationale as ``Inflater``.
public final class Deflater {
    public enum DeflaterError: Error, Equatable {
        case initFailed(Int32)
        case streamError(Int32)
    }

    /// Flush modes that callers care about, wrapped so that consumers
    /// don't have to `import CZlib`.
    public enum Flush {
        /// Compress what's available without forcing output. Used for
        /// throughput-oriented streaming.
        case none
        /// Force the encoder to emit a sync point. Matches what an
        /// MCCP2 server typically emits between logical messages.
        case sync
        /// End the stream. Output is final after this; the deflater
        /// shouldn't receive more input.
        case finish

        fileprivate var rawValue: Int32 {
            switch self {
            case .none: Z_NO_FLUSH
            case .sync: Z_SYNC_FLUSH
            case .finish: Z_FINISH
            }
        }
    }

    private var stream: z_stream
    private var scratch: [UInt8]

    public init(level: Int32 = Z_DEFAULT_COMPRESSION, scratchCapacity: Int = 65536) throws {
        stream = z_stream()
        scratch = [UInt8](repeating: 0, count: scratchCapacity)
        let result = deflateInit_(
            &stream,
            level,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.stride)
        )
        guard result == Z_OK else {
            throw DeflaterError.initFailed(result)
        }
    }

    deinit {
        _ = deflateEnd(&stream)
    }

    /// Compress `input` and return whatever bytes the encoder has
    /// produced so far. Use `flush: .sync` between logical messages and
    /// `flush: .finish` when the stream is ending.
    public func deflate(_ input: [UInt8], flush: Flush = .sync) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count + 64)

        if input.isEmpty, flush == .none {
            return output
        }

        let rawFlush = flush.rawValue

        try input.withUnsafeBufferPointer { (inBuf: UnsafeBufferPointer<UInt8>) in
            stream.next_in = UnsafeMutablePointer(
                mutating: inBuf.baseAddress
            )
            stream.avail_in = UInt32(inBuf.count)

            repeat {
                try scratch.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(outBuf.count)
                    let before = stream.avail_out
                    let status = CZlib.deflate(&stream, rawFlush)
                    let produced = Int(before - stream.avail_out)
                    if produced > 0 {
                        output.append(
                            contentsOf: outBuf[0..<produced]
                        )
                    }
                    switch status {
                    case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                        break
                    default:
                        throw DeflaterError.streamError(status)
                    }
                }
            } while stream.avail_out == 0
        }

        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0
        return output
    }

    /// Convenience: compress everything in one call with a sync flush.
    public func compress(_ input: [UInt8]) throws -> [UInt8] {
        try deflate(input, flush: .sync)
    }
}
