@testable import MudCore
import Testing

@Suite("External communication capture compatibility")
struct ExternalChatCaptureCompatTests {
    @Test("storeFromOutside preserves timestamp, omit-log, and explicit-link arguments")
    func options() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        CallPlugin(
          'b555825a4a5700c35fa80780', 'storeFromOutside', 'click here', 'Q/A',
          false, true, '{{start=1, stop=5, text="help links", label="Help"}}'
        )
        """)
        guard case .externalChatCapture(
            let text, let tab, let showsTimestamp, let shouldPersist, let linksJSON
        ) = effects.last else {
            Issue.record("missing advanced capture effect")
            return
        }
        #expect(text == "click here")
        #expect(tab == "Q/A")
        #expect(!showsTimestamp)
        #expect(!shouldPersist)
        #expect(linksJSON?.contains("help links") == true)
    }

    @Test("numeric tabs remain distinct in the native dynamic tab model")
    func numericTab() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let effects = try await lua.run("""
        CallPlugin('b555825a4a5700c35fa80780', 'storeFromOutside', 'hello', 2)
        """)
        #expect(effects.last == .chatCapture(text: "hello", channel: "Tab 2"))
    }
}
