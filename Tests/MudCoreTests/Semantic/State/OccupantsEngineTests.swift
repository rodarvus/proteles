import Foundation
@testable import MudCore
import Testing

/// Occupants through the engine's seams (S0b item 2, #84): `room.info`
/// binds names to the room, a sent consider opens the window, and an
/// override is saved and re-resolves the names.
@Suite("Occupants — engine seams", .serialized)
struct OccupantsEngineTests {
    /// Records the entities each state change names.
    private struct Spy: NativePlugin {
        let metadata = NativePluginMetadata(
            id: "test.occupants-spy",
            name: "Spy",
            author: "t",
            version: "1",
            summary: ""
        )
        mutating func onStateChange(
            _: ActionableState,
            changed: Set<ActionableState.Entity>
        ) -> [ScriptEffect] {
            [.echo("changed: \(changed.map { "\($0)" }.sorted().joined(separator: ","))")]
        }
    }

    private func echoes(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .echo(let text) = $0 { text } else { nil } }
    }

    @Test("a sent consider is read, bound to the room, and keyed; an override is saved")
    func endToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("occupants-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobKeywordOverrideStore(url: directory.appendingPathComponent("MobKeywords.db"))

        let engine = try ScriptEngine()
        await engine.setKeywordSources(MobKeywordSources(overrides: store, sndDatabase: nil))
        await engine.registerNativePlugin(Spy())
        let connect = await engine.connectNativePlugins()
        #expect(echoes(connect) == ["changed: keywords"])

        _ = await engine.applyGMCP(package: "room.info", json: #"{ "num": 32418, "zone": "radiance" }"#)
        await engine.noteRoomConsider()
        _ = await engine.process(line: "A male villager should be a fair fight!")
        let closed = await engine.process(line: "[60640/62217hp 21149/21149mn]>")
        #expect(echoes(closed.effects) == ["changed: occupants"])
        let named = try #require(await engine.actionableState.occupants?.named)
        #expect(named.room == 32418)
        #expect(named.area == "radiance")
        #expect(named.mobs.first?.keyword == .init(keyword: "male villa", source: .guess))

        let set = await engine.setMobKeywordOverride("villager", for: "A male villager", area: "radiance")
        #expect(echoes(set) == ["changed: keywords,occupants"])
        #expect(await engine.actionableState.occupants?.named?.mobs.first?.keyword
            == .init(keyword: "villager", source: .player))
        #expect(store.load() == ["radiance": ["a male villager": "villager"]])

        // A new connection reloads it from the store.
        _ = await engine.connectNativePlugins()
        #expect(await engine.actionableState.keywords.resolve("A male villager", area: "radiance")
            .source == .player)

        let moved = await engine.applyGMCP(
            package: "room.info",
            json: #"{ "num": 32419, "zone": "radiance" }"#
        )
        #expect(!echoes(moved).contains("changed: occupants"), "no names to drop after a reconnect")
    }
}
