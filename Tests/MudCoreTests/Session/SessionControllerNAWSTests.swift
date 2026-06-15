@testable import MudCore
import Testing

/// NAWS (telnet option 31) window-size payload: `IAC SB NAWS <16-bit cols>
/// <16-bit rows> IAC SE`, big-endian, with any `0xFF` value byte doubled.
@Suite("SessionController — NAWS payload")
struct SessionControllerNAWSTests {
    // IAC=255, SB=250, NAWS=31, SE=240.

    @Test("standard 80x24 → IAC SB NAWS 0 80 0 24 IAC SE")
    func standard() {
        #expect(SessionController.nawsPayload(columns: 80, rows: 24)
            == [255, 250, 31, 0, 80, 0, 24, 255, 240])
    }

    @Test("a 0xFF value byte is doubled (IAC escaping): 255 columns")
    func escapesIAC() {
        // 255 = high 0, low 0xFF → the 0xFF is doubled.
        #expect(SessionController.nawsPayload(columns: 255, rows: 1)
            == [255, 250, 31, 0, 255, 255, 0, 1, 255, 240])
    }

    @Test("wide values use the high byte: 256 columns")
    func highByte() {
        #expect(SessionController.nawsPayload(columns: 256, rows: 50)
            == [255, 250, 31, 1, 0, 0, 50, 255, 240])
    }
}
