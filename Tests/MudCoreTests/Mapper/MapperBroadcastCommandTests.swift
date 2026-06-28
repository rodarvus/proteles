import Foundation
@testable import MudCore
import Testing

@Suite("Mapper — command broadcast parity")
struct MapperBroadcastCommandTests {
    private func seeded() async throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-broadcast-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"North End","zone":"z","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Middle","zone":"z","exits":{"n":3}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"South End","zone":"z","exits":{"n":2}}"#
        )
        return (mapper, url)
    }

    private func walkCommands(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { if case .execute(let text) = $0 { text } else { nil } }
    }

    private func mapperBroadcasts(_ effects: [ScriptEffect]) -> [(id: Int, text: String)] {
        effects.compactMap {
            if case .mapperBroadcast(let id, let text) = $0 { (id, text) } else { nil }
        }
    }

    @Test("mapper goto emits 500/501 before walk effects")
    func gotoBroadcastsBeforeWalk() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        let effects = await mapper.handleCommand("mapper goto 3")
        let broadcasts = mapperBroadcasts(effects)
        #expect(broadcasts.map(\.id) == [500, 501])
        #expect(broadcasts[0].text.contains(#"["3"]"#))
        #expect(broadcasts[0].text.contains(#"reason = true"#))
        #expect(broadcasts[1].text == "unfound_paths = {  }")
        #expect(walkCommands(effects) == ["run 2n"])
        if effects.count >= 2 {
            if case .mapperBroadcast = effects[0] {} else {
                Issue.record("first effect should be 500 broadcast")
            }
            if case .mapperBroadcast = effects[1] {} else {
                Issue.record("second effect should be 501 broadcast")
            }
        }
    }

    @Test("mapper walkto broadcasts the non-portal path")
    func walktoBroadcastsNonPortalPath() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await mapper.handleCommand("mapper fullportal {enter portal} {3} 0")

        let effects = await mapper.handleCommand("mapper walkto 3")
        let broadcasts = mapperBroadcasts(effects)
        #expect(broadcasts.map(\.id) == [500, 501])
        #expect(broadcasts.first?.text.contains(#"dir = "n""#) == true)
        #expect(broadcasts.first?.text.contains("enter portal") == false)
        #expect(walkCommands(effects) == ["run 2n"])
    }

    @Test("mapper findpath emits 502 without walking")
    func findpathBroadcasts502() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }

        let effects = await mapper.handleCommand("mapper findpath 1 3")
        let broadcasts = mapperBroadcasts(effects)
        #expect(broadcasts.map(\.id) == [MapperPluginBridge.foundPathBroadcast])
        #expect(broadcasts.first?.text ==
            #"found_paths = { { dir = "n", uid = "2" }, { dir = "n", uid = "3" } }"#)
        #expect(walkCommands(effects).isEmpty)
    }
}
