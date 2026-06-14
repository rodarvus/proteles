import Foundation
@testable import MudCore
import Testing

/// The host-side variable API behind the Scripts window's Variables tab (#69):
/// reads merge the live runtime with the on-disk store, and writes hot-update
/// the runtime AND persist to disk.
@Suite("SessionController — variables API (#69)")
struct SessionControllerVariablesTests {
    private func makeController() async throws -> (SessionController, VariableStore) {
        let engine = try ScriptEngine()
        let controller = SessionController(scriptEngine: engine)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proteles-vars-\(UUID().uuidString).json")
        let store = VariableStore(url: url)
        await controller.attachVariableStore(store)
        return (controller, store)
    }

    @Test("set then read reflects the value and persists to the store")
    func setAndRead() async throws {
        let (controller, store) = try await makeController()
        await controller.setVariable(scope: "_user", name: "target", value: "kobold")

        let scopes = await controller.variableScopes()
        #expect(scopes["_user"]?["target"] == "kobold")
        // The runtime change was flushed to disk via persistVariablesIfDirty.
        #expect(await store.scopes["_user"]?["target"] == "kobold")
    }

    @Test("delete removes the variable from both runtime and store")
    func delete() async throws {
        let (controller, store) = try await makeController()
        await controller.setVariable(scope: "_user", name: "a", value: "1")
        await controller.deleteVariable(scope: "_user", name: "a")

        let scopes = await controller.variableScopes()
        #expect(scopes["_user"]?["a"] == nil)
        #expect(await store.scopes["_user"]?["a"] == nil)
    }

    @Test("rename carries the value to the new name and drops the old")
    func rename() async throws {
        let (controller, _) = try await makeController()
        await controller.setVariable(scope: "_user", name: "old", value: "v")
        await controller.renameVariable(scope: "_user", from: "old", to: "new", value: "v")

        let scopes = await controller.variableScopes()
        #expect(scopes["_user"]?["old"] == nil)
        #expect(scopes["_user"]?["new"] == "v")
    }

    @Test("variableScopes overlays a hydrated store scope the runtime didn't set")
    func storeOverlay() async throws {
        let (controller, store) = try await makeController()
        // A plugin scope seeded into the store, then re-hydrated into the engine.
        try await store.update(scope: "pluginX", variables: ["k": "v"])
        await controller.attachVariableStore(store) // re-hydrates the engine

        let scopes = await controller.variableScopes()
        #expect(scopes["pluginX"]?["k"] == "v")
    }
}
