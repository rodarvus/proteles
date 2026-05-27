@testable import MudCore
import Testing

@Suite("SessionController — connection preference setters")
struct SessionControllerConnectionPrefsTests {
    @Test("setReconnectEnabled toggles the policy between standard and disabled")
    func reconnectToggle() async {
        let session = SessionController(reconnectPolicy: .standard)
        await session.setReconnectEnabled(false)
        #expect(await session.reconnectPolicy.isEnabled == false)
        await session.setReconnectEnabled(true)
        #expect(await session.reconnectPolicy.isEnabled)
    }

    @Test("setAutoRecord toggles the auto-record flag")
    func autoRecordToggle() async {
        let session = SessionController(autoRecord: false)
        await session.setAutoRecord(true)
        #expect(await session.autoRecord)
        await session.setAutoRecord(false)
        #expect(await session.autoRecord == false)
    }
}
