import Foundation
@testable import MudCore
import Testing

/// #52 — S&D host variables persist across sessions. The host runs S&D on
/// its own runtime, so the engine-side store wiring never saw its
/// `SetVariable` writes: every session re-scraped the area index and the
/// `xset` flags (autonav!) reset. Now the session hydrates the host's scope
/// from the per-world ``VariableStore`` BEFORE `load()` (S&D reads
/// `GetVariable` at script top-level) and `persistVariablesIfDirty` drains
/// the host's dirty scopes like the engine's.
@Suite("S&D — variable persistence (#52)")
struct SnDVariablePersistenceTests {
    init() {
        SnDFixture.install()
    }

    private func notes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap {
            if case .colourNote(let segs) = $0 { return segs.map(\.text).joined() }
            if case .note(let text, _, _) = $0 { return text }
            return nil
        }
    }

    @Test("hydration lands before load — the script's top-level GetVariable sees it")
    func hydrationBeforeLoad() async throws {
        let host = try SearchAndDestroyHost()
        // Persisted "on" → the first toggle must flip to OFF (the local
        // `xset_autonav_onoff` hydrates at script top-level; an un-hydrated
        // load defaults to "off" and would flip to ON).
        await host.hydrateVariables(["mcvar_xset_autonav_onoff": "on"])
        try await host.load()
        let first = try #require(await host.expandCommand("xset autonav"))
        #expect(notes(first).contains { $0.contains("Auto-navigate") && $0.contains("OFF") })
    }

    @Test("SetVariable writes mark the S&D scope dirty and snapshot the value")
    func dirtyDrain() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        _ = await host.takeDirtyVariableScopes() // clear load-time writes
        _ = await host.expandCommand("xset autonav")
        let dirty = await host.takeDirtyVariableScopes()
        #expect(dirty.contains(SearchAndDestroyHost.pluginID))
        let snapshot = await host.variablesSnapshot()
        #expect(snapshot[SearchAndDestroyHost.pluginID]?["mcvar_xset_autonav_onoff"] == "on")
        // Drained — a second take is empty until the next write.
        #expect(await host.takeDirtyVariableScopes().isEmpty)
    }

    @Test("full round trip: toggle → store file → fresh host starts from it")
    func roundTripThroughStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-vars-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // Session 1: attach the store, toggle autonav on, quit-save.
        let first = SessionController()
        await first.attachVariableStore(VariableStore(url: url))
        let host = try SearchAndDestroyHost()
        await first.hydrateSearchAndDestroyVariables(host)
        try await host.load()
        await first.attachSearchAndDestroy(host)
        #expect(await first.handleSearchAndDestroyCommand("xset autonav"))
        await first.savePluginState()

        let json = try String(decoding: Data(contentsOf: url), as: UTF8.self)
        #expect(json.contains("mcvar_xset_autonav_onoff"))

        // Session 2: a fresh store read + fresh host — autonav is still on,
        // so the first toggle flips OFF.
        let second = SessionController()
        await second.attachVariableStore(VariableStore(url: url))
        let rehydrated = try SearchAndDestroyHost()
        await second.hydrateSearchAndDestroyVariables(rehydrated)
        try await rehydrated.load()
        await second.attachSearchAndDestroy(rehydrated)
        let effects = try #require(await rehydrated.expandCommand("xset autonav"))
        #expect(notes(effects).contains { $0.contains("Auto-navigate") && $0.contains("OFF") })
    }
}
