@testable import MudCore
import Testing

@Suite("Search-and-Destroy — model decode")
struct SearchAndDestroyModelTests {
    @Test("A populated campaign snapshot decodes with all per-target fields")
    func decodesPopulated() throws {
        let json = """
        {
          "version": "Search & Destroy v5.99",
          "activity": "cp",
          "player_on_cp": true,
          "player_on_gq": false,
          "target_count": 3,
          "targets": [
            { "index": 1, "mob": "a city guard", "room": "Gate House", "area": "aylor",
              "link_type": "room", "current": true },
            { "index": 2, "mob": "the gatekeeper", "area": "aylor", "link_type": "area",
              "express": true, "duplicates": 3, "dup_index": 1 },
            { "index": 3, "mob": "a temple acolyte", "area": "chakra", "link_type": "area",
              "unlikely": true, "dead": true, "qty": 2 }
          ]
        }
        """
        let model = try #require(SearchAndDestroyModel.decode(json))
        #expect(model.activity == "cp")
        #expect(model.activityLabel == "Campaign")
        #expect(model.playerOnCP)
        #expect(model.targets.count == 3)

        let first = model.targets[0]
        #expect(first.mob == "a city guard")
        #expect(first.current)
        #expect(first.linkType == "room")

        let second = model.targets[1]
        #expect(second.express)
        #expect(second.duplicates == 3 && second.dupIndex == 1)

        let third = model.targets[2]
        #expect(third.unlikely && third.dead)
        #expect(third.qty == 2)
    }

    @Test("Missing fields default sensibly; bad JSON returns nil")
    func tolerant() {
        let minimal = SearchAndDestroyModel.decode(#"{"activity":"none"}"#)
        #expect(minimal?.activityLabel == "Idle")
        #expect(minimal?.targets.isEmpty == true)
        #expect(minimal?.playerOnCP == false)
        #expect(SearchAndDestroyModel.decode("not json") == nil)
    }
}
