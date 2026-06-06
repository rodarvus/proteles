@testable import MudCore
import Testing

@Suite("Lua console — /lua one-off eval (#41)")
struct LuaConsoleTests {
    @Test("an expression echoes its value")
    func expressionValue() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.evaluateConsole("2 + 2")
        #expect(effects == [.note(text: "lua: = 4", foreground: "cyan", background: nil)])
    }

    @Test("a string expression echoes via tostring")
    func stringExpression() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.evaluateConsole("'a' .. 'b'")
        #expect(effects == [.note(text: "lua: = ab", foreground: "cyan", background: nil)])
    }

    @Test("print output is captured as effects")
    func printCapture() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim() // installs the global `print` → Note override
        let effects = await engine.evaluateConsole("print('hello')")
        #expect(effects.contains { effect in
            switch effect {
            case .echo(let text): text == "hello"
            case .note(let text, _, _): text == "hello"
            default: false
            }
        })
    }

    @Test("a syntax error becomes a single red note (no crash)")
    func syntaxError() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.evaluateConsole("this is not )( lua")
        #expect(effects.count == 1)
        guard case .note(let text, let foreground, _) = effects.first else {
            Issue.record("expected a note"); return
        }
        #expect(foreground == "red")
        #expect(text.hasPrefix("lua: error:"))
    }

    @Test("side effects run exactly once — compile-tested, never trial-run")
    func noDoubleExecution() async throws {
        let engine = try ScriptEngine()
        // `proteles.echo(..)` is a valid expression, so it takes the expression
        // path; it must NOT also run via a statement fallback.
        let effects = await engine.evaluateConsole("proteles.echo('once')")
        let echoes = effects.filter { if case .echo("once") = $0 { return true }; return false }
        #expect(echoes.count == 1)
    }

    @Test("statements (assignments, loops) run and persist")
    func statements() async throws {
        let engine = try ScriptEngine()
        _ = await engine.evaluateConsole("__lc = 7")
        let effects = await engine.evaluateConsole("__lc * 2")
        #expect(effects == [.note(text: "lua: = 14", foreground: "cyan", background: nil)])
    }

    @Test("empty `/lua` shows a usage hint")
    func usage() async throws {
        let engine = try ScriptEngine()
        let effects = await engine.evaluateConsole("   ")
        #expect(effects.count == 1)
        if case .note(_, let foreground, _) = effects.first { #expect(foreground == "yellow") }
    }

    @Test("`/lua …` command parsing (case-insensitive, gated prefix)")
    func commandParsing() {
        #expect(SessionController.luaConsoleCode("/lua 2+2") == "2+2")
        #expect(SessionController.luaConsoleCode("/LUA foo()") == "foo()")
        #expect(SessionController.luaConsoleCode("  /lua  x = 1") == "x = 1")
        #expect(SessionController.luaConsoleCode("/lua")?.isEmpty == true)
        #expect(SessionController.luaConsoleCode("look") == nil)
        #expect(SessionController.luaConsoleCode("/luademic") == nil)
    }
}
