@testable import MudCore
import Testing

/// `LuaSourceContext` — the "context" half of the native traceback feature:
/// locate the failing frame in a known chunk + the source window around it.
@Suite("LuaSourceContext — error source context")
struct LuaSourceContextTests {
    @Test("window returns the offending line + neighbours, tagged")
    func window() {
        let lines = LuaSourceContext.window(source: "a\nb\nc\nd\ne", line: 3, radius: 1)
        #expect(lines == [
            LuaSourceContext.WindowLine(number: 2, text: "b", isError: false),
            LuaSourceContext.WindowLine(number: 3, text: "c", isError: true),
            LuaSourceContext.WindowLine(number: 4, text: "d", isError: false)
        ])
    }

    @Test("window clamps to file bounds; nil out of range")
    func windowBounds() {
        #expect(LuaSourceContext.window(source: "only", line: 1, radius: 5)?.count == 1)
        #expect(LuaSourceContext.window(source: "only", line: 5) == nil)
    }

    @Test("topFrame finds the innermost known-chunk frame, skipping [C]/unknown frames")
    func topFrame() {
        let message = """
        shared_core:12: attempt to call a nil value
        stack traceback:
        \t[C]: in function 'error'
        \tshared_core:12: in function 'cast'
        \tother:3: in main chunk
        """
        let frame = LuaSourceContext.topFrame(in: message, knownChunks: ["shared_core", "other"])
        #expect(frame?.chunk == "shared_core")
        #expect(frame?.line == 12)
    }

    @Test("topFrame is nil when no frame names a known chunk")
    func topFrameUnknown() {
        let message = "[string \"x\"]:1: boom\nstack traceback:\n\t[C]: in ?"
        #expect(LuaSourceContext.topFrame(in: message, knownChunks: ["shared_core"]) == nil)
    }

    @Test("the runtime emits Sath-style coloured context for a retained chunk")
    func runtimeEnrichment() throws {
        let runtime = try LuaRuntime()
        runtime.rememberChunkSource("mymod", "function f()\n  bad()\nend")
        let effects = runtime.sourceContextEffects(
            forError: "mymod:2: attempt to call a nil value\nstack traceback:\n\tmymod:2: in function 'f'"
        )
        #expect(!effects.isEmpty)
        // the offending line's text is shown, highlighted black-on-white
        let highlighted = effects.contains { effect in
            guard case .colourNote(let segments) = effect else { return false }
            return segments.contains { $0.text.contains("bad()") && $0.background == "white" }
        }
        #expect(highlighted)
    }

    @Test("no context for a console one-liner / unknown chunk")
    func noContextWhenUnknown() throws {
        let runtime = try LuaRuntime()
        #expect(runtime.sourceContextEffects(forError: "[string \"x\"]:1: boom").isEmpty)
    }
}
