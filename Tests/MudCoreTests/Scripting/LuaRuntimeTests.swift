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
