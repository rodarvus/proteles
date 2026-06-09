@testable import MudCore
import Testing

/// Regression for the login bug: Aardwolf's gateway compresses EACH frame as an
/// independent raw-deflate stream, so a single continuous inflater decodes the
/// first frame (banner) but yields nothing for the second (the `Password:`
/// prompt) — silently breaking autologin. These are two REAL captured frames.
@Suite("WebSocketFraming — independent per-frame deflate (#ws login)")
struct WebSocketMultiFrameTests {
    private static let banner =
        "rdVNS8NAEAbge6F3b75sD4uQUDyJ5iCiPfpxqT2IJGu6pUJMZE0tAX+g/qZQ1tl+0DVN6FYyh0DTzNN3"
            + "JrDV5aMuh7qc6PJblz96MdGLI7047rVZnW6v94TD6tmR830fI5nE2ZtEnuFKqPE8Sya4Hd4sv6vj0GdA"
            + "O+mA0I8YY9xDLfeQiEKqD1zPlJJpnhS4T5PXVF7g9PyswhmLre+cbAL+N51lUX3Z3MH11wIC2MM6IyG9"
            + "jzCsWFY2d442ZRDP252dskXmvju3mS7gfEejbB43qCu3Tka1i1FFjMOJw2pdwd53TfFWHc0cUYwZMHTG"
            + "mjizKzOfue7TLKyBQ+RvkT1cALuzYViAMdoapWPLFketeXdA325y05rT9SttTlrD7ioYVeSk1XE1mGM2"
            + "w/ltVqdrfmeQ5lKhyGYK8VQoEZuPqaAzPlPIi3cJfjcYcXPix0qKXEIglfPtw62nGk1Fjhf6j5kWyyAe"
            + "xPiTTvSZkuoSvw=="
    private static let passwordFrame =
        "4+J1rcgsLsnMS1coKMpPy8xJVcjJT0xJTVHQVSjISU0sTlVIzStJLVKozC8tUihILC4uzy9K0ePi5eIN"
            + "gHKsFP7/ZgQA"

    @Test("consecutive frames each decode through one reused inflater")
    func twoFramesDecode() throws {
        let inflater = try Inflater(raw: true)
        let first = WebSocketFraming.inboundBytes(fromBase64: Self.banner, inflater: inflater)
        let second = WebSocketFraming.inboundBytes(fromBase64: Self.passwordFrame, inflater: inflater)
        #expect(String(bytes: first, encoding: .isoLatin1)?.contains("Aardwolf") == true)
        // The bug: this was empty (continuous inflater couldn't decode frame 2).
        #expect(String(bytes: second, encoding: .isoLatin1)?.contains("Password:") == true)
    }
}
