@testable import MudUI
import Testing

@Suite("CommandInputView smoke")
struct CommandInputViewSmokeTests {
    @Test("CommandInputView constructs with a submission closure")
    func constructsWithSubmissionClosure() {
        // Phase 1 smoke: SwiftUI views are exercised through previews and
        // app-level integration. This test catches build-time regressions
        // — the view must compile and accept a closure of the documented
        // shape.
        _ = CommandInputView { _ in }
    }
}
