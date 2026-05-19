import CZlib
import Foundation

/// Streaming zlib decompressor — the "inbound" half of MCCP2 (PLAN.md §5.3).
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

    /// `scratchCapacity` sets the size of the temporary output buffer
    /// used per `inflate()` syscall. Larger = fewer zlib calls per chunk
    /// at the cost of memory. 64 KiB matches NWConnection's typical
    /// receive size.
    public init(scratchCapacity: Int = 65536) throws {
        stream = z_stream()
        scratch = [UInt8](repeating: 0, count: scratchCapacity)
        let result = inflateInit_(
            &stream,
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
        guard !input.isEmpty else { return [] }
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 4)

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
                    case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                        // Z_BUF_ERROR after producing zero bytes simply
                        // means "needs more input"; safe to return.
                        if status == Z_BUF_ERROR, produced == 0 {
                            stream.avail_in = 0
                        }
                    default:
                        throw InflaterError.dataError(status)
                    }
                }
            }
        }

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
