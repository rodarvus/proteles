@testable import MudUI
import Testing

@Suite("MudUI smoke")
struct MudUISmokeTests {
    @Test("StatusBarView constructs in every connection state")
    func statusBarConstructs() {
        _ = StatusBarView(state: .disconnected)
        _ = StatusBarView(state: .connecting)
        _ = StatusBarView(state: .connected)
        _ = StatusBarView(state: .reconnecting)
    }
}
