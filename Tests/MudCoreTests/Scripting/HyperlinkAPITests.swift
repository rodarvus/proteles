@testable import MudCore
import Testing

@Suite("Hyperlink API — proteles.hyperlink + mush Hyperlink")
struct HyperlinkAPITests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    private func segments(_ effects: [ScriptEffect]) -> [NoteSegment]? {
        if case .colourNote(let segs)? = effects.last { return segs }
        return nil
    }

    @Test("proteles.hyperlink emits a clickable segment; URL action → openURL")
    func protelesHyperlinkURL() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run(#"proteles.hyperlink("click here", "http://x.io", "go")"#)
        #expect(segments(effects) == [
            NoteSegment(text: "click here", link: LineLink(action: .openURL("http://x.io"), hint: "go"))
        ])
    }

    @Test("mush Hyperlink: a non-URL action becomes a sendCommand link")
    func mushHyperlinkCommand() async throws {
        let lua = try await shimmed()
        // Hyperlink(action, text, hint) — MUSHclient arg order.
        let effects = try await lua.run(#"Hyperlink("look sign", "examine the sign")"#)
        #expect(segments(effects) == [
            NoteSegment(text: "examine the sign", link: LineLink(action: .sendCommand("look sign")))
        ])
    }

    @Test("LineLink(actionString:) classifies URLs vs commands")
    func actionStringClassification() {
        #expect(LineLink(actionString: "https://a.b").action == .openURL("https://a.b"))
        #expect(LineLink(actionString: "mailto:x@y.z").action == .openURL("mailto:x@y.z"))
        #expect(LineLink(actionString: "north").action == .sendCommand("north"))
    }

    @Test("Proteles command-link URI round-trips and rejects unsafe forms")
    func commandLinkURIRoundTrip() {
        let url = CommandLinkURI.url(for: "mapper goto 35004")
        #expect(url?.absoluteString == "proteles-cmd:///mapper%20goto%2035004")
        #expect(url.flatMap { CommandLinkURI.decode($0.absoluteString) } == "mapper goto 35004")
        #expect(CommandLinkURI.decode("proteles-cmd://mapper%20goto%2035004") == nil)
        #expect(CommandLinkURI.decode("proteles-cmd:///proteles-cmd%3A%2F%2F%2Flook") == nil)
        #expect(CommandLinkURI.decode("proteles-cmd:///say%20hi%0Anorth") == nil)
    }
}
