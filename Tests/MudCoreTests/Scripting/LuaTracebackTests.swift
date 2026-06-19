@testable import MudCore
import Testing

/// Runtime errors carry a Lua call stack (the `__proteles_traceback` message
/// handler installed via ``LuaRuntime/protectedCall``), so a plugin author sees
/// *where* a script failed, not just the top-line message.
@Suite("Lua traceback — error reports include the call stack")
struct LuaTracebackTests {
    private let nested = """
    local function inner() error("boom") end
    local function outer() inner() end
    outer()
    """

    @Test("a console error note includes the stack traceback + the failing frames")
    func consoleTraceback() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.evaluateConsole(nested)
        #expect(effects.count == 1)
        guard case .note(let text, let foreground, _) = effects.first else {
            Issue.record("expected a note"); return
        }
        #expect(foreground == "red")
        #expect(text.contains("boom")) // the original message survives
        #expect(text.contains("stack traceback")) // the stack was appended
        #expect(text.contains("inner")) // the failing function…
        #expect(text.contains("outer")) // …and its caller
    }

    @Test("a thrown runtime error (run path) carries the traceback too")
    func runTraceback() async throws {
        let runtime = try LuaRuntime()
        do {
            _ = try await runtime.run(nested)
            Issue.record("expected the chunk to throw")
        } catch let LuaRuntime.LuaError.runtime(message) {
            #expect(message.contains("boom"))
            #expect(message.contains("stack traceback"))
        }
    }

    @Test("a clean expression still echoes its value (no regression)")
    func cleanStillWorks() async throws {
        let engine = try ScriptEngine()
        #expect(await engine.evaluateConsole("2 + 2")
            == [.note(text: "lua: = 4", foreground: "cyan", background: nil)])
    }
}
