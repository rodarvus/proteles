import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — loadstring / serialize / json helpers")
struct JSONSerializeHelpersTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("loadstring compiles and runs a chunk")
    func loadstringRuns() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local f = loadstring("proteles.echo('from loadstring')")
        f()
        """)
        #expect(effects == [.echo("from loadstring")])
    }

    @Test("loadstring returns nil + message on a syntax error")
    func loadstringSyntaxError() async throws {
        let lua = try await shimmed()
        #expect(try await lua.boolean("(loadstring('this is not lua ===')) == nil"))
    }

    @Test("serialize.save round-trips a table through loadstring")
    func serializeSaveRoundTrip() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        require "serialize"
        local saved = serialize.save("mobs", { count = 3, name = "rat" })
        mobs = nil
        loadstring(saved)()
        proteles.echo(mobs.name .. ":" .. tostring(mobs.count))
        """)
        #expect(effects == [.echo("rat:3")])
    }

    @Test("serialize.save_simple emits a loadable literal")
    func serializeSaveSimple() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        require "serialize"
        local literal = serialize.save_simple({ a = 1, b = "x" })
        local t = loadstring("return " .. literal)()
        proteles.echo(tostring(t.a) .. t.b)
        """)
        #expect(effects == [.echo("1x")])
    }

    @Test("serialize round-trips every Lua keyword as a nested string key")
    func serializeReservedKeys() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        require "serialize"
        local value = { ordinary = "kept", [1] = "number", [false] = "boolean", ["two words"] = "spaced" }
        local words = "and break do else elseif end false for function if in local nil not or " ..
                      "repeat return then true until while"
        for key in words:gmatch("%S+") do value[key] = { [key] = key } end
        local simple = assert(loadstring("return " .. serialize.save_simple(value)))()
        assert(loadstring(serialize.save("restored", value)))()
        for _, result in ipairs({simple, restored}) do
          assert(result.ordinary == "kept" and result[1] == "number")
          assert(result[false] == "boolean" and result["two words"] == "spaced")
          local count = 0
          for key in words:gmatch("%S+") do
            assert(result[key][key] == key)
            count = count + 1
          end
          proteles.echo(tostring(count))
        end
        """)
        #expect(effects == [.echo("21"), .echo("21")])
    }

    @Test("json.decode parses into a Lua table")
    func jsonDecode() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local json = require "json"
        local t = json.decode('{"hp": 42, "tags": ["a", "b"]}')
        proteles.echo(tostring(t.hp) .. ":" .. t.tags[1] .. t.tags[2])
        """)
        #expect(effects == [.echo("42:ab")])
    }

    @Test("json.encode produces JSON that decodes back equal")
    func jsonRoundTrip() async throws {
        let lua = try await shimmed()
        let effects = try await lua.run("""
        local json = require "json"
        local original = { name = "rat", level = 5 }
        local back = json.decode(json.encode(original))
        proteles.echo(back.name .. ":" .. tostring(back.level))
        """)
        #expect(effects == [.echo("rat:5")])
    }

    @Test("json.encode emits an array for a 1..n table")
    func jsonEncodeArray() async throws {
        let lua = try await shimmed()
        #expect(try await lua.string(
            "(function() local json = require 'json'; return json.encode({10, 20, 30}) end)()"
        ) == "[10,20,30]")
    }
}
