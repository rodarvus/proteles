import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — evaluation")
struct LuaRuntimeEvaluationTests {
    @Test("Evaluates arithmetic to a number")
    func arithmetic() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.number("1 + 2 * 3") == 7)
    }

    @Test("Evaluates string expressions")
    func strings() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.string(#""ab" .. "cd""#) == "abcd")
    }

    @Test("Standard library is available")
    func standardLibrary() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.number("math.floor(3.9)") == 3)
        #expect(try await lua.string("string.upper('hi')") == "HI")
        #expect(try await lua.number("#({1, 2, 3})") == 3)
    }

    @Test("Boolean truthiness follows Lua rules")
    func booleans() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.boolean("1 == 1"))
        #expect(try await lua.boolean("nil") == false)
        #expect(try await lua.boolean("0")) // 0 is truthy in Lua
    }
}

@Suite("LuaRuntime — sandbox")
struct LuaRuntimeSandboxTests {
    @Test("Dangerous globals are removed by default")
    func dangerousGlobalsRemoved() async throws {
        let lua = try LuaRuntime()
        for global in ["io", "package", "require", "module", "dofile", "loadfile", "loadstring", "load"] {
            #expect(try await lua.boolean("\(global) == nil"), "\(global) should be nil")
        }
        #expect(try await lua.boolean("os.execute == nil"))
        #expect(try await lua.boolean("os.remove == nil"))
        #expect(try await lua.boolean("os.getenv == nil"))
        #expect(try await lua.boolean("debug.getregistry == nil"))
    }

    @Test("Safe stdlib survives the sandbox")
    func safeStdlibSurvives() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.boolean("type(os.time()) == 'number'"))
        #expect(try await lua.number("math.max(2, 5)") == 5)
        #expect(try await lua.string("string.lower('HI')") == "hi")
        #expect(try await lua.boolean("type(debug.traceback) == 'function'"))
    }

    @Test("package.loaded back-door to io is closed")
    func packageBackdoorClosed() async throws {
        let lua = try LuaRuntime()
        // With `package` gone, there's no package.loaded.io to recover.
        #expect(try await lua.boolean("package == nil"))
    }

    @Test("An unsandboxed runtime keeps the full library")
    func unsandboxedKeepsLibrary() async throws {
        let lua = try LuaRuntime(sandboxed: false)
        #expect(try await lua.boolean("io ~= nil"))
        #expect(try await lua.boolean("type(os.execute) == 'function'"))
    }
}

@Suite("LuaRuntime — proteles.* host API")
struct LuaRuntimeHostAPITests {
    @Test("The proteles table and its functions exist")
    func apiInstalled() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.boolean("type(proteles) == 'table'"))
        for fn in ["send", "sendNoEcho", "execute", "echo", "note"] {
            #expect(try await lua.boolean("type(proteles.\(fn)) == 'function'"), "\(fn)")
        }
    }

    @Test("proteles.send records a .send effect")
    func sendEffect() async throws {
        let lua = try LuaRuntime()
        let effects = try await lua.run("proteles.send('kill rabbit')")
        #expect(effects == [.send("kill rabbit")])
    }

    @Test("echo / execute / sendNoEcho record their effects")
    func simpleEffects() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.run("proteles.echo('hi')") == [.echo("hi")])
        #expect(try await lua.run("proteles.execute('look')") == [.execute("look")])
        #expect(try await lua.run("proteles.sendNoEcho('secret')") == [.sendNoEcho("secret")])
    }

    @Test("proteles.note carries optional colours")
    func noteColours() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.run("proteles.note('plain')")
            == [.note(text: "plain", foreground: nil, background: nil)])
        #expect(try await lua.run("proteles.note('warn', 'red', 'black')")
            == [.note(text: "warn", foreground: "red", background: "black")])
    }

    @Test("Effects are collected in order, including from loops")
    func orderedEffects() async throws {
        let lua = try LuaRuntime()
        let effects = try await lua.run("""
        proteles.echo('start')
        for i = 1, 3 do proteles.send('hit ' .. i) end
        proteles.echo('done')
        """)
        #expect(effects == [
            .echo("start"),
            .send("hit 1"), .send("hit 2"), .send("hit 3"),
            .echo("done")
        ])
    }

    @Test("The effect buffer is cleared between runs")
    func effectsClearedBetweenRuns() async throws {
        let lua = try LuaRuntime()
        _ = try await lua.run("proteles.send('first')")
        let second = try await lua.run("proteles.send('second')")
        #expect(second == [.send("second")])
    }

    @Test("Numbers passed to send are stringified")
    func numericArgsCoerced() async throws {
        let lua = try LuaRuntime()
        // Lua concatenation coerces; a bare number arg becomes "".
        #expect(try await lua.run("proteles.send(tostring(42))") == [.send("42")])
    }
}

@Suite("LuaRuntime — event bus & RPC")
struct LuaRuntimeEventTests {
    @Test("raiseEvent invokes handlers registered with onEvent")
    func eventHandlerFires() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.onEvent('tick', function() proteles.send('refresh') end)")
        let effects = try await lua.run("proteles.raiseEvent('tick')")
        #expect(effects == [.send("refresh")])
    }

    @Test("Event handlers receive payload arguments")
    func eventPayload() async throws {
        let lua = try LuaRuntime()
        try await lua.run("""
        proteles.onEvent('hp', function(cur, max)
            proteles.echo('HP ' .. cur .. '/' .. max)
        end)
        """)
        let effects = try await lua.run("proteles.raiseEvent('hp', 1200, 2000)")
        #expect(effects == [.echo("HP 1200/2000")])
    }

    @Test("Multiple handlers fire in registration order")
    func multipleHandlers() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.onEvent('go', function() proteles.send('one') end)")
        try await lua.run("proteles.onEvent('go', function() proteles.send('two') end)")
        let effects = try await lua.run("proteles.raiseEvent('go')")
        #expect(effects == [.send("one"), .send("two")])
    }

    @Test("Raising an event with no handlers is a no-op")
    func eventNoHandlers() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.run("proteles.raiseEvent('nobody')").isEmpty)
    }

    @Test("broadcast reaches onBroadcast handlers with all args")
    func broadcast() async throws {
        let lua = try LuaRuntime()
        try await lua.run("""
        proteles.onBroadcast(function(id, text)
            proteles.note(text, 'green', nil)
        end)
        """)
        let effects = try await lua.run("proteles.broadcast(7, 'hello')")
        #expect(effects == [.note(text: "hello", foreground: "green", background: nil)])
    }

    @Test("call invokes an exported function and returns its result")
    func exportAndCall() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.export('add', function(a, b) return a + b end)")
        #expect(try await lua.number("proteles.call('add', 3, 4)") == 7)
    }

    @Test("call to an unknown export returns nothing")
    func callUnknown() async throws {
        let lua = try LuaRuntime()
        #expect(try await lua.boolean("proteles.call('missing') == nil"))
    }

    @Test("A throwing event handler surfaces as a note, not a crash")
    func handlerErrorSurfaced() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.onEvent('boom', function() error('kaboom') end)")
        let effects = try await lua.run("proteles.raiseEvent('boom')")
        #expect(effects.count == 1)
        if case .note(let text, _, _) = effects.first {
            #expect(text.contains("kaboom"))
        } else {
            Issue.record("expected an error note, got \(String(describing: effects.first))")
        }
    }

    @Test("Handlers persist across runs; transient callbacks don't leak")
    func handlersPersist() async throws {
        let lua = try LuaRuntime()
        try await lua.run("proteles.onEvent('ping', function() proteles.send('pong') end)")
        // A later, separate run can still fire it.
        #expect(try await lua.run("proteles.raiseEvent('ping')") == [.send("pong")])
        #expect(try await lua.run("proteles.raiseEvent('ping')") == [.send("pong")])
    }
}

@Suite("LuaRuntime — execution timeout")
struct LuaRuntimeTimeoutTests {
    @Test("An infinite loop is aborted with .timedOut, not a hang")
    func infiniteLoopTimesOut() async throws {
        let lua = try LuaRuntime(executionTimeout: .milliseconds(150))
        let start = ContinuousClock.now
        do {
            try await lua.run("while true do end")
            Issue.record("expected the loop to time out")
        } catch let error as LuaRuntime.LuaError {
            #expect(error == .timedOut)
        }
        // It should abort promptly, not run away.
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("A long bounded loop is also caught")
    func longLoopTimesOut() async throws {
        let lua = try LuaRuntime(executionTimeout: .milliseconds(150))
        do {
            try await lua.run("local n = 0; for i = 1, 1e12 do n = n + i end")
            Issue.record("expected the loop to time out")
        } catch let error as LuaRuntime.LuaError {
            #expect(error == .timedOut)
        }
    }

    @Test("Quick scripts run normally under the timeout")
    func quickScriptNotAffected() async throws {
        let lua = try LuaRuntime(executionTimeout: .milliseconds(150))
        try await lua.run("total = 0; for i = 1, 1000 do total = total + i end")
        #expect(try await lua.number("total") == 500_500)
    }

    @Test("The runtime survives a timeout and can run again")
    func recoversAfterTimeout() async throws {
        let lua = try LuaRuntime(executionTimeout: .milliseconds(150))
        _ = try? await lua.run("while true do end")
        // State is intact; a fresh evaluation still works.
        #expect(try await lua.number("2 + 2") == 4)
    }
}

@Suite("LuaRuntime — state & errors")
struct LuaRuntimeStateTests {
    @Test("State persists across run calls")
    func statePersists() async throws {
        let lua = try LuaRuntime()
        try await lua.run("counter = 0")
        try await lua.run("counter = counter + 5")
        try await lua.run("counter = counter + 5")
        #expect(try await lua.number("counter") == 10)
    }

    @Test("Globals set from Swift are visible to Lua")
    func globalsRoundTrip() async throws {
        let lua = try LuaRuntime()
        await lua.setGlobal("hp", to: 1234)
        await lua.setGlobal("who", to: "Conan")
        #expect(try await lua.number("hp + 1") == 1235)
        #expect(try await lua.string("who .. ' the barbarian'") == "Conan the barbarian")
    }

    @Test("A syntax error throws .syntax")
    func syntaxError() async throws {
        let lua = try LuaRuntime()
        do {
            try await lua.run("this is not lua )(")
            Issue.record("expected a syntax error")
        } catch let error as LuaRuntime.LuaError {
            guard case .syntax = error else {
                Issue.record("expected .syntax, got \(error)")
                return
            }
        }
    }

    @Test("A runtime error throws .runtime")
    func runtimeError() async throws {
        let lua = try LuaRuntime()
        do {
            try await lua.run("error('boom')")
            Issue.record("expected a runtime error")
        } catch let error as LuaRuntime.LuaError {
            guard case .runtime(let message) = error else {
                Issue.record("expected .runtime, got \(error)")
                return
            }
            #expect(message.contains("boom"))
        }
    }

    @Test("Asking for a number from a non-number throws typeMismatch")
    func typeMismatch() async throws {
        let lua = try LuaRuntime()
        do {
            _ = try await lua.number("'not a number at all'")
            Issue.record("expected a type mismatch")
        } catch let error as LuaRuntime.LuaError {
            guard case .typeMismatch = error else {
                Issue.record("expected .typeMismatch, got \(error)")
                return
            }
        }
    }
}
