import CZlib
import Foundation

/// Streaming zlib decompressor — the "inbound" half of MCCP2 (ARCHITECTURE.md §5.3).
///
/// A single `Inflater` instance holds one `z_stream` for the lifetime of a
/// compressed session. Compressed bytes arrive in arbitrary chunks (e.g.
/// from `NWConnection.receive`); ``inflate(_:)`` returns whatever plain
/// bytes the stream can produce *so far* from the cumulative input.
/// Partial multi-byte sequences are buffered internally by zlib until
/// enough input arrives.
///
/// Errors:
///   - ``InflaterError/initFailed(_:)`` if `inflateInit_` fails (rare;
///     usually means zlib couldn't allocate state).
///   - ``InflaterError/dataError(_:)`` if the compressed stream is
///     corrupted or contains an invalid sequence.
///
/// The class is **not** Sendable — `z_stream` holds C pointers that are
/// only safe to touch from one isolation domain. In MudCore, the owning
/// `SessionController` actor is that domain.
public final class Inflater {
    public enum InflaterError: Error, Equatable {
        case initFailed(Int32)
        case dataError(Int32)
    }

    private var stream: z_stream
    private var scratch: [UInt8]

    /// True when the most recent ``inflate(_:)`` reached the end of the
    /// compressed stream (`Z_STREAM_END`). With MCCP2 this is the signal that
    /// the server ended compression — notably during an Aardwolf **ice age**
    /// (copyover): the old zlib stream is finished and the bytes that follow are
    /// plaintext telnet re-negotiation. The caller must then stop decompressing
    /// (drop this inflater) and process ``leftover`` + subsequent bytes as
    /// plaintext, where a fresh `COMPRESS2` subnegotiation restarts compression.
    public private(set) var streamEnded = false
    /// Input bytes that followed the end of the compressed stream and were NOT
    /// consumed — the plaintext tail after `Z_STREAM_END`. Empty unless
    /// ``streamEnded`` is true. Reset at the start of each ``inflate(_:)``.
    public private(set) var leftover: [UInt8] = []

    /// `scratchCapacity` sets the size of the temporary output buffer
    /// used per `inflate()` syscall. Larger = fewer zlib calls per chunk
    /// at the cost of memory. 64 KiB matches NWConnection's typical
    /// receive size.
    ///
    /// `raw` selects **headerless DEFLATE** (zlib `windowBits = -15`) instead of
    /// the zlib-wrapped stream MCCP2 uses (`+15`). Aardwolf's WebSocket gateway
    /// frames its telnet stream as raw deflate (no `0x78` header), so the
    /// WebSocket transport constructs `Inflater(raw: true)`.
    public init(scratchCapacity: Int = 65536, raw: Bool = false) throws {
        stream = z_stream()
        scratch = [UInt8](repeating: 0, count: scratchCapacity)
        let result = inflateInit2_(
            &stream,
            raw ? -15 : 15,
            zlibVersion(),
            Int32(MemoryLayout<z_stream>.stride)
        )
        guard result == Z_OK else {
            throw InflaterError.initFailed(result)
        }
    }

    deinit {
        _ = inflateEnd(&stream)
    }

    /// Feed compressed bytes into the stream. Returns whatever plain
    /// bytes have become available so far. An empty return is normal
    /// when zlib needs more input to produce output.
    public func inflate(_ input: [UInt8]) throws -> [UInt8] {
        streamEnded = false
        leftover = []
        guard !input.isEmpty else { return [] }
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 4)
        var ended = false
        var tail: [UInt8] = []

        try input.withUnsafeBufferPointer { (inBuf: UnsafeBufferPointer<UInt8>) in
            stream.next_in = UnsafeMutablePointer(
                mutating: inBuf.baseAddress
            )
            stream.avail_in = UInt32(inBuf.count)

            while stream.avail_in > 0 {
                try scratch.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(outBuf.count)
                    let before = stream.avail_out
                    let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    let produced = Int(before - stream.avail_out)
                    if produced > 0 {
                        output.append(
                            contentsOf: outBuf[0..<produced]
                        )
                    }
                    switch status {
                    case Z_STREAM_END:
                        // End of the compressed stream. Any bytes zlib didn't
                        // consume are a plaintext tail (e.g. an Aardwolf
                        // copyover's telnet re-negotiation) — capture them and
                        // stop, rather than re-feeding a finished stream (which
                        // would spin or error).
                        ended = true
                        let remaining = Int(stream.avail_in)
                        if remaining > 0 {
                            tail = Array(input[(input.count - remaining)...])
                        }
                        stream.avail_in = 0
                    case Z_OK:
                        break
                    case Z_BUF_ERROR:
                        // Z_BUF_ERROR after producing zero bytes simply
                        // means "needs more input"; safe to return.
                        if produced == 0 { stream.avail_in = 0 }
                    default:
                        throw InflaterError.dataError(status)
                    }
                }
                if ended { break }
            }
        }
        streamEnded = ended
        leftover = tail

        // zlib leaves dangling pointers in the stream struct after the
        // input buffer goes out of scope. Clearing them avoids
        // surprises if a subsequent inflate is called with no input.
        stream.next_in = nil
        stream.avail_in = 0
        stream.next_out = nil
        stream.avail_out = 0
        return output
    }

    /// Reset the stream state for re-use within the same actor. Equivalent
    /// to constructing a new ``Inflater`` but cheaper.
    public func reset() throws {
        let result = inflateReset(&stream)
        guard result == Z_OK else {
            throw InflaterError.initFailed(result)
        }
    }
}
