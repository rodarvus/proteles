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
