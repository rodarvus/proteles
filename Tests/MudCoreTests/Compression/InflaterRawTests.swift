import Foundation
@testable import MudCore
import Testing

@Suite("Inflater — raw deflate (WebSocket gateway, #ws)")
struct InflaterRawTests {
    @Test("raw mode inflates headerless DEFLATE (wbits -15)")
    func rawInflate() throws {
        // Produced by: zlib.compressobj(6, DEFLATED, -15) over the test string.
        let b64 = "80jNyclXcEwsSinPz0lTyC9LLVIIT00Kzk/OTi0BAA=="
        let bytes = try [UInt8](#require(Data(base64Encoded: b64)))
        let inflater = try Inflater(raw: true)
        let out = try inflater.inflate(bytes)
        #expect(String(bytes: out, encoding: .utf8) == "Hello Aardwolf over WebSocket")
    }
}
