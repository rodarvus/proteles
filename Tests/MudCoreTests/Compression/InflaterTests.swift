@testable import MudCore
import Testing

@Suite("Deflater + Inflater — round-trip")
struct CompressionRoundTripTests {
    @Test("Compress then decompress recovers the original ASCII bytes")
    func roundTripASCII() throws {
        let plain = Array("Hello, Aardwolf!".utf8)
        let deflater = try Deflater()
        let compressed = try deflater.compress(plain)
        #expect(compressed.first == 0x78, "missing zlib CMF byte")

        let inflater = try Inflater()
        let recovered = try inflater.inflate(compressed)
        #expect(recovered == plain)
    }

    @Test("Round-trip works on a large payload with repeated text")
    func roundTripLargePayload() throws {
        // Repetitive payload compresses well — verifies the streaming
        // output path handles multiple inflate() iterations per call.
        let segment = Array(
            "The Drunken Boxer growls and lunges at you!\r\n".utf8
        )
        var plain: [UInt8] = []
        for _ in 0..<200 {
            plain.append(contentsOf: segment)
        }

        let deflater = try Deflater()
        let compressed = try deflater.compress(plain)
        #expect(compressed.count < plain.count, "no compression happened?")

        let inflater = try Inflater()
        let recovered = try inflater.inflate(compressed)
        #expect(recovered == plain)
    }

    @Test("Empty input through deflate then inflate is empty")
    func emptyRoundTrip() throws {
        let inflater = try Inflater()
        let recovered = try inflater.inflate([])
        #expect(recovered.isEmpty)
    }

    @Test("UTF-8 payload survives a round-trip byte-identically")
    func utf8RoundTrip() throws {
        let plain = Array("Welcome to the misty café — try the gâteau.".utf8)
        let deflater = try Deflater()
        let compressed = try deflater.compress(plain)
        let inflater = try Inflater()
        let recovered = try inflater.inflate(compressed)
        #expect(recovered == plain)
        #expect(
            String(decoding: recovered, as: UTF8.self)
                == "Welcome to the misty café — try the gâteau."
        )
    }
}

@Suite("Inflater — streaming across multiple calls")
struct InflaterStreamingTests {
    @Test("Compressed payload split byte-by-byte still decompresses")
    func streamingByteByByte() throws {
        let plain = Array("streaming text payload".utf8)
        let deflater = try Deflater()
        let compressed = try deflater.compress(plain)

        let inflater = try Inflater()
        var recovered: [UInt8] = []
        for byte in compressed {
            let chunk = try inflater.inflate([byte])
            recovered.append(contentsOf: chunk)
        }
        #expect(recovered == plain)
    }

    @Test("Two separate compressed segments inflate cumulatively")
    func multipleCompressedSegments() throws {
        // Simulates a real MCCP2 session: the server emits compressed
        // bytes over multiple TCP packets. The deflater's Z_SYNC_FLUSH
        // boundary between segments mirrors what a streaming server
        // produces.
        let deflater = try Deflater()
        let seg1Plain = Array("first part\r\n".utf8)
        let seg2Plain = Array("second part\r\n".utf8)
        let seg1Compressed = try deflater.deflate(seg1Plain, flush: .sync)
        let seg2Compressed = try deflater.deflate(seg2Plain, flush: .sync)

        let inflater = try Inflater()
        let firstOut = try inflater.inflate(seg1Compressed)
        let secondOut = try inflater.inflate(seg2Compressed)
        #expect(firstOut == seg1Plain)
        #expect(secondOut == seg2Plain)
    }
}

@Suite("Inflater — error handling")
struct InflaterErrorTests {
    @Test("Corrupted input throws InflaterError.dataError")
    func corruptedInputThrows() throws {
        let plain = Array("data".utf8)
        let deflater = try Deflater()
        var compressed = try deflater.compress(plain)
        // Trash bytes in the middle of the compressed stream so the
        // Adler/length checks fail.
        if compressed.count > 4 {
            for index in 2..<min(compressed.count, 8) {
                compressed[index] = 0xFF
            }
        }

        let inflater = try Inflater()
        do {
            _ = try inflater.inflate(compressed)
            Issue.record("expected InflaterError.dataError")
        } catch let error as Inflater.InflaterError {
            switch error {
            case .dataError: break
            default: Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("End-of-stream is reported with the unconsumed plaintext tail")
    func streamEndExposesLeftover() throws {
        // A finished (Z_FINISH) stream followed by trailing plaintext bytes —
        // the shape an Aardwolf copyover produces (compressed stream ends, then
        // plaintext telnet re-negotiation). Pre-fix this hung / errored.
        let deflater = try Deflater()
        let compressed = try deflater.deflate(Array("hello\n".utf8), flush: .finish)
        let tail: [UInt8] = [0xFF, 0xFA, 86, 0xFF, 0xF0] // IAC SB MCCP2 IAC SE

        let inflater = try Inflater()
        let recovered = try inflater.inflate(compressed + tail)
        #expect(String(decoding: recovered, as: UTF8.self) == "hello\n")
        #expect(inflater.streamEnded)
        #expect(inflater.leftover == tail)
    }

    @Test("A normal (open) stream does not report end-of-stream")
    func openStreamNotEnded() throws {
        let deflater = try Deflater()
        let compressed = try deflater.deflate(Array("still going\n".utf8), flush: .sync)
        let inflater = try Inflater()
        _ = try inflater.inflate(compressed)
        #expect(!inflater.streamEnded)
        #expect(inflater.leftover.isEmpty)
    }

    @Test("output larger than the scratch buffer is fully drained in one call (#56)")
    func drainsPendingOutputPastScratchCapacity() throws {
        // The audit's Z_BUF_ERROR corner (#56): highly compressible input
        // means zlib consumes ALL input bytes early, then generates output
        // from its window over several buffer-fulls. A drain loop gated only
        // on `avail_in > 0` exits after the first full scratch buffer and
        // strands the rest inside zlib until the next network packet — on a
        // quiet line, indefinitely.
        let plain = [UInt8](repeating: UInt8(ascii: "A"), count: 4096)
        let deflater = try Deflater()
        let compressed = try deflater.deflate(plain, flush: .sync)

        let inflater = try Inflater(scratchCapacity: 64)
        let recovered = try inflater.inflate(compressed)
        #expect(recovered == plain)
    }

    @Test("pathological split: tail chunk that expands past scratch still drains (#56)")
    func drainsPendingOutputAcrossSplitChunks() throws {
        let plain = [UInt8](repeating: UInt8(ascii: "B"), count: 8192)
        let deflater = try Deflater()
        let compressed = try deflater.deflate(plain, flush: .sync)

        // Split mid-stream so the final chunk carries the bulk of the
        // expansion; each call must still return everything available.
        let inflater = try Inflater(scratchCapacity: 64)
        let mid = compressed.count / 2
        var recovered = try inflater.inflate(Array(compressed[0..<mid]))
        recovered += try inflater.inflate(Array(compressed[mid...]))
        #expect(recovered == plain)
    }

    @Test("worst case: byte-by-byte input through an 8-byte scratch buffer (#56)")
    func drainsByteByByteThroughTinyScratch() throws {
        // Every inflate() call has at most one input byte and an output
        // buffer 512× smaller than the expansion — maximal pressure on the
        // drain loop's exit condition.
        let plain = [UInt8](repeating: UInt8(ascii: "C"), count: 4096)
        let deflater = try Deflater()
        let compressed = try deflater.deflate(plain, flush: .sync)

        let inflater = try Inflater(scratchCapacity: 8)
        var recovered: [UInt8] = []
        for byte in compressed {
            recovered += try inflater.inflate([byte])
        }
        #expect(recovered == plain)
    }

    @Test("reset() returns the inflater to a fresh state")
    func resetAllowsReuse() throws {
        let plain = Array("first session".utf8)
        let deflater = try Deflater()
        let compressed = try deflater.compress(plain)

        let inflater = try Inflater()
        _ = try inflater.inflate(compressed)
        try inflater.reset()

        let deflater2 = try Deflater()
        let plain2 = Array("second session".utf8)
        let compressed2 = try deflater2.compress(plain2)
        let recovered = try inflater.inflate(compressed2)
        #expect(recovered == plain2)
    }
}
