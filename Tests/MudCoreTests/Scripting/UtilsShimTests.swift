import Foundation
@testable import MudCore
import Testing

@Suite("LuaRuntime — utils library shim")
struct UtilsShimTests {
    private func shimmed() async throws -> LuaRuntime {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        return lua
    }

    @Test("split returns the separated pieces")
    func split() async throws {
        let lua = try await shimmed()
        #expect(try await lua.string("table.concat(utils.split('a,b,c', ','), '|')") == "a|b|c")
        #expect(try await lua.string("table.concat(utils.split('1 2', ' '), '|')") == "1|2")
        #expect(try await lua.number("#utils.split('', ',')") == 1)
    }

    @Test("tohex/fromhex round-trip; base64 round-trips")
    func hexAndBase64() async throws {
        let lua = try await shimmed()
        #expect(try await lua.string("utils.tohex('AB')") == "4142")
        #expect(try await lua.string("utils.fromhex('4142')") == "AB")
        #expect(try await lua.string("utils.base64encode('Man')") == "TWFu")
        #expect(try await lua.string("utils.base64decode('TWFu')") == "Man")
        #expect(try await lua
            .string("utils.base64decode(utils.base64encode('hello world'))") == "hello world")
    }

    @Test("edit_distance is Levenshtein; timer is sub-second wall time")
    func distanceAndTimer() async throws {
        let lua = try await shimmed()
        #expect(try await lua.number("utils.edit_distance('kitten', 'sitting')") == 3)
        #expect(try await lua.number("utils.edit_distance('abc', 'abc')") == 0)
        #expect(try await lua.number("utils.timer()") > 1_000_000_000)
    }

    @Test("GUI dialogs are safe stubs (no crash, sensible defaults)")
    func guiStubs() async throws {
        let lua = try await shimmed()
        #expect(try await lua.boolean("utils.inputbox('q') == nil"))
        #expect(try await lua.boolean("utils.editbox('m', 't') == nil"))
        #expect(try await lua.boolean("utils.listbox('m', 't', {}) == nil"))
        #expect(try await lua.string("utils.msgbox('hi')") == "ok")
        #expect(try await lua.number("#utils.getfontfamilies()") == 0)
        #expect(try await lua.string("utils.metaphone('test')") == "test")
        #expect(try await lua.boolean("type(utils.hash('x')) == 'string'"))
    }

    @Test("readdir/makeDirectory are sandbox-scoped to the allowed directory")
    func filesystemScoped() async throws {
        let lua = try LuaRuntime()
        try await lua.loadCompatShim()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("utils-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await lua.setSQLiteDirectory(dir.path)

        // A path outside the allowed dir is never visible / creatable.
        #expect(try await lua.boolean("utils.readdir('/etc') == nil"))
        #expect(try await lua.boolean(#"proteles.makeDirectory("/etc/proteles_should_deny") == false"#))

        // Inside the allowed dir: mkdir via shellexecute, then readdir sees it.
        let target = dir.appendingPathComponent("sub/child").path
        _ = try await lua.run(#"utils.shellexecute("cmd", "/C mkdir \"\#(target)\"", "", "open", 0)"#)
        #expect(FileManager.default.fileExists(atPath: target))
        #expect(try await lua.boolean(#"utils.readdir("\#(target)") ~= nil"#))
    }
}
