import Foundation
@testable import MudCore
import Testing

@Suite("Mapper — CallPlugin bridge")
struct MapperPluginBridgeTests {
    private func seeded() async throws -> (Mapper, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-bridge-\(UUID().uuidString).db")
        let mapper = try Mapper(store: MapperStore(url: url))
        // Corridor 1—n→2—n→3, current room 1, area "aylor" named "Aylor".
        _ = await mapper.ingest(package: "room.area", json: #"{"id":"aylor","name":"Aylor"}"#)
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":3,"name":"End","zone":"aylor","exits":{}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":2,"name":"Mid","zone":"aylor","exits":{"n":3}}"#
        )
        _ = await mapper.ingest(
            package: "room.info",
            json: #"{"num":1,"name":"Start","zone":"aylor","exits":{"n":2}}"#
        )
        return (mapper, url)
    }

    @Test("found_paths serialises a route as the Aardwolf Lua literal")
    func foundPathsLiteral() {
        let targets = [MapperPluginBridge.Target(
            uid: "3",
            reason: "shop",
            path: [PathStep(dir: "n", uid: "2"), PathStep(dir: "n", uid: "3")]
        )]
        let text = MapperPluginBridge.foundPaths(targets)
        #expect(text.hasPrefix("found_paths = {"))
        #expect(text.contains(#"["3"]"#))
        #expect(text.contains(#"dir = "n""#))
        #expect(text.contains(#"uid = "2""#))
        #expect(text.contains(#"reason = "shop""#))
    }

    @Test("unfound_paths lists only the routeless targets")
    func unfoundPathsLiteral() {
        let targets = [
            MapperPluginBridge.Target(uid: "3", reason: nil, path: [PathStep(dir: "n", uid: "3")]),
            MapperPluginBridge.Target(uid: "9", reason: "boss", path: nil)
        ]
        let text = MapperPluginBridge.unfoundPaths(targets)
        #expect(text.contains(#"uid = "9""#))
        #expect(text.contains(#"reason = "boss""#))
        #expect(!text.contains(#"uid = "3""#)) // 3 had a path → not listed
    }

    @Test("get_current_room returns the current uid")
    func getCurrentRoom() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await mapper.handlePluginCall("get_current_room", args: [])
        #expect(result.results == ["1"])
    }

    @Test("getkeyword matches area key or name, comma-joined")
    func getKeyword() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await mapper.handlePluginCall("getkeyword", args: ["ayl"]).results == ["aylor"])
        #expect(await mapper.handlePluginCall("getkeyword", args: ["nope"]).results == [""])
    }

    @Test("find broadcasts 500 found + 501 unfound for reachable/unreachable targets")
    func findBroadcasts() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await mapper.handlePluginCall("find", args: ["3,9999"])
        #expect(result.broadcasts.count == 2)
        let found = result.broadcasts.first { $0.id == MapperPluginBridge.foundPathsBroadcast }
        let unfound = result.broadcasts.first { $0.id == MapperPluginBridge.unfoundPathsBroadcast }
        // Room 3 is reachable (n,n); 9999 is not.
        #expect(found?.text.contains(#"["3"]"#) == true)
        #expect(found?.text.contains(#"["9999"]"#) == false)
        #expect(unfound?.text.contains(#"uid = "9999""#) == true)
    }

    @Test("findpath with source and destination broadcasts the reference path list")
    func findPathFromSourceBroadcasts502() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await mapper.handlePluginCall("findpath", args: ["2", "3", "true", "true"])
        #expect(result.results == ["1"])
        #expect(result.broadcasts.count == 1)
        #expect(result.broadcasts.first?.id == MapperPluginBridge.foundPathBroadcast)
        #expect(result.broadcasts.first?.text == #"found_paths = { { dir = "n", uid = "3" } }"#)
    }

    @Test("Unknown functions are a graceful no-op")
    func unknownFunction() async throws {
        let (mapper, url) = try await seeded()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await mapper.handlePluginCall("not_a_real_function", args: ["x"])
        #expect(result == MapperCallResult())
    }
}
