@testable import MudCore
import Testing

@Suite("GetInfo(280/281) — live output geometry (#30)")
struct GetInfoGeometryTests {
    @Test("reflects the reported output-view size")
    func reportedSize() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim()
        await engine.setOutputGeometry(width: 1024, height: 768)
        // 281 = client width, 280 = client height (MUSHclient semantics).
        #expect(await engine.evaluateConsole("GetInfo(281)")
            == [.note(text: "lua: = 1024", foreground: "cyan", background: nil)])
        #expect(await engine.evaluateConsole("GetInfo(280)")
            == [.note(text: "lua: = 768", foreground: "cyan", background: nil)])
    }

    @Test("defaults to 800×600 before the app reports a size")
    func defaultsBeforeReport() async throws {
        let engine = try ScriptEngine()
        try await engine.loadCompatShim()
        #expect(await engine.evaluateConsole("GetInfo(281)")
            == [.note(text: "lua: = 800", foreground: "cyan", background: nil)])
        #expect(await engine.evaluateConsole("GetInfo(280)")
            == [.note(text: "lua: = 600", foreground: "cyan", background: nil)])
    }
}

@Suite("proteles.databaseDir() — per-character DB dir for plugins (#43/#44)")
struct DatabaseDirTests {
    @Test("returns the directory the session set")
    func returnsSetDir() async throws {
        let engine = try ScriptEngine()
        await engine.setDatabasesDirectory("/Users/x/Documents/Proteles/Databases/Rodarvus/")
        #expect(await engine.evaluateConsole("proteles.databaseDir()")
            == [.note(
                text: "lua: = /Users/x/Documents/Proteles/Databases/Rodarvus/",
                foreground: "cyan",
                background: nil
            )])
    }

    @Test("empty before the session sets it")
    func emptyByDefault() async throws {
        let engine = try ScriptEngine()
        #expect(await engine.evaluateConsole("proteles.databaseDir()")
            == [.note(text: "lua: = ", foreground: "cyan", background: nil)])
    }
}
