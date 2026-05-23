@testable import MudCore
import Testing

@Suite("Search-and-Destroy — host (S1.2)")
struct SearchAndDestroyHostTests {
    @Test("core.lua loads on the curated runtime; its functions are defined")
    func loadsCore() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // A handful of S&D's functions should now be callable globals.
        #expect(await host.functionExists("init_plugin"))
        #expect(await host.functionExists("migrate_database"))
        #expect(await host.functionExists("OnPluginBroadcast"))
    }
}
