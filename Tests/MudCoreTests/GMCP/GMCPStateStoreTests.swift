import Foundation
@testable import MudCore
import Testing

@Suite("GMCPStateStore — apply")
struct GMCPStateStoreApplyTests {
    @Test("Char.Vitals updates the vitals slot")
    func appliesVitals() async {
        let store = GMCPStateStore()
        let message = GMCPMessage(package: "Char.Vitals", json: #"{"hp":1234,"mana":900,"moves":500}"#)
        let changed = await store.apply(message)
        #expect(changed)
        let state = await store.state
        #expect(state.vitals == CharVitals(hp: 1234, mana: 900, moves: 500))
    }

    @Test("Char.MaxStats with only the vital maxima decodes (stats optional)")
    func appliesMaxStatsPartial() async {
        let store = GMCPStateStore()
        let message = GMCPMessage(
            package: "Char.MaxStats",
            json: #"{"maxhp":2000,"maxmana":1500,"maxmoves":1000}"#
        )
        #expect(await store.apply(message))
        let max = await store.state.maxStats
        #expect(max?.maxhp == 2000)
        #expect(max?.maxstr == nil)
    }

    @Test("Char.Stats decodes the trainable stats + hit/damage roll")
    func appliesStats() async {
        let store = GMCPStateStore()
        let message = GMCPMessage(
            package: "char.stats",
            json: #"{"str":200,"int":150,"wis":160,"dex":180,"con":190,"luck":120,"hr":520,"dr":480}"#
        )
        #expect(await store.apply(message))
        let stats = await store.state.stats
        #expect(stats == CharStats(
            str: 200, int: 150, wis: 160, dex: 180, con: 190, luck: 120, hr: 520, dr: 480
        ))
    }

    @Test("Char.Status decodes level and align")
    func appliesStatus() async {
        let store = GMCPStateStore()
        let message = GMCPMessage(package: "Char.Status", json: #"{"level":201,"tnl":0,"align":1000}"#)
        #expect(await store.apply(message))
        let status = await store.state.status
        #expect(status?.level == 201)
        #expect(status?.align == 1000)
    }

    @Test("Lowercase wire casing (real Aardwolf payloads) is accepted")
    func realAardwolfCasingAndShapes() async {
        let store = GMCPStateStore()
        // Verbatim payloads captured from a live Aardwolf session.
        _ = await store.apply(GMCPMessage(
            package: "char.vitals",
            json: #"{ "hp": 2226, "mana": 1861, "moves": 1021 }"#
        ))
        // Real payloads carry extra keys (hunger, thirst, state, pos,
        // tier, …) which our structs ignore; trimmed here to fit the line
        // limit while keeping the keys we decode.
        _ = await store.apply(GMCPMessage(
            package: "char.maxstats",
            json: #"{ "maxhp": 2226, "maxmana": 1861, "maxmoves": 1021, "maxstr": 72 }"#
        ))
        _ = await store.apply(GMCPMessage(
            package: "char.status",
            json: #"{ "level": 51, "tnl": 2826, "align": 2500, "state": 3, "enemy": "" }"#
        ))
        _ = await store.apply(GMCPMessage(
            package: "char.base",
            json: #"{ "name": "Rodarvus", "class": "Psionicist", "race": "Eldar", "level": 51 }"#
        ))

        let state = await store.state
        #expect(state.vitals == CharVitals(hp: 2226, mana: 1861, moves: 1021))
        #expect(state.maxStats?.maxhp == 2226)
        #expect(state.maxStats?.maxstr == 72)
        #expect(state.status?.level == 51)
        #expect(state.status?.align == 2500)
        #expect(state.base?.class == "Psionicist")
        #expect(state.base?.race == "Eldar")
    }

    @Test("room.info decodes name, zone, and exits")
    func appliesRoom() async {
        let store = GMCPStateStore()
        // Shape from a live capture (name carries @-codes), trimmed to fit.
        let json = #"""
        { "num": 2339, "name": "@GA Light Provisions Room@w", "zone": "light",
          "terrain": "inside", "exits": { "n": 2343, "e": 2341 },
          "coord": { "id": 0, "x": 30, "y": 20, "cont": 0 } }
        """#
        #expect(await store.apply(GMCPMessage(package: "room.info", json: json)))
        let room = await store.state.room
        #expect(room?.num == 2339)
        #expect(room?.zone == "light")
        #expect(room?.exits?["n"] == 2343)
        #expect(AardwolfColor.stripped(room?.name ?? "") == "A Light Provisions Room")
    }

    @Test("group with members decodes (string-valued member info)")
    func appliesGroupWithMembers() async {
        let store = GMCPStateStore()
        let json = #"""
        { "groupname": "The A-Team", "leader": "Hannibal", "members": [
            { "name": "Hannibal", "info": { "lvl": "201", "hp": "3000", "mhp": "3000", "here": "1" } },
            { "name": "Murdock", "info": { "lvl": "150", "hp": "900", "mhp": "1800", "here": "0" } }
        ] }
        """#
        #expect(await store.apply(GMCPMessage(package: "group", json: json)))
        let group = await store.state.group
        #expect(group?.isGrouped == true)
        #expect(group?.leader == "Hannibal")
        #expect(group?.members?.count == 2)
        let murdock = group?.members?.first { $0.name == "Murdock" }
        #expect(murdock?.info?.level == 150)
        #expect(murdock?.info?.hpCurrent == 900)
        #expect(murdock?.info?.hpMax == 1800)
        #expect(murdock?.info?.isHere == false)
    }

    @Test("group with no members is not grouped")
    func appliesGroupEmpty() async {
        let store = GMCPStateStore()
        let json = #"{ "groupname": "", "reason": "no group" }"#
        #expect(await store.apply(GMCPMessage(package: "group", json: json)))
        let group = await store.state.group
        #expect(group?.isGrouped == false)
        #expect(group?.reason == "no group")
    }

    @Test("An unknown package is ignored")
    func ignoresUnknown() async {
        let store = GMCPStateStore()
        let changed = await store.apply(GMCPMessage(package: "Foo.Bar", json: "{}"))
        #expect(!changed)
        #expect(await store.state == GMCPState())
    }

    @Test("A malformed payload leaves the prior state intact")
    func malformedKeepsPriorState() async {
        let store = GMCPStateStore()
        _ = await store.apply(GMCPMessage(package: "Char.Vitals", json: #"{"hp":10,"mana":20,"moves":30}"#))
        // Missing required keys → decode fails → no change.
        let changed = await store.apply(GMCPMessage(package: "Char.Vitals", json: #"{"hp":99}"#))
        #expect(!changed)
        #expect(await store.state.vitals == CharVitals(hp: 10, mana: 20, moves: 30))
    }

    @Test("reset clears all state")
    func resetClears() async {
        let store = GMCPStateStore()
        _ = await store.apply(GMCPMessage(package: "Char.Vitals", json: #"{"hp":1,"mana":2,"moves":3}"#))
        await store.reset()
        #expect(await store.state == GMCPState())
    }

    @Test("subscribe delivers the current snapshot, then updates")
    func subscribeDeliversCurrentThenUpdates() async {
        let store = GMCPStateStore()
        _ = await store.apply(GMCPMessage(package: "Char.Status", json: #"{"level":5}"#))

        let stream = await store.subscribe()
        var iterator = stream.makeAsyncIterator()

        // First element is the current snapshot.
        let first = await iterator.next()
        #expect(first?.status?.level == 5)

        _ = await store.apply(GMCPMessage(package: "Char.Status", json: #"{"level":6}"#))
        let second = await iterator.next()
        #expect(second?.status?.level == 6)
    }
}

@Suite("GMCPMessage — encoding & handshake")
struct GMCPEncodingTests {
    @Test("encode frames a payload as IAC SB 201 … IAC SE")
    func framesPayload() {
        let bytes = GMCPMessage.encode(payload: "request char")
        #expect(bytes.first == TelnetCommand.iac)
        #expect(bytes[1] == TelnetCommand.sb)
        #expect(bytes[2] == TelnetOption.gmcp)
        #expect(Array(bytes.suffix(2)) == [TelnetCommand.iac, TelnetCommand.se])
        let inner = Array(bytes[3..<(bytes.count - 2)])
        #expect(inner == Array("request char".utf8))
    }

    @Test("A JSON payload passes through unaltered (no stray IAC)")
    func jsonPayloadUnaltered() {
        // GMCP payloads are UTF-8 JSON, which never contains a raw 0xFF
        // byte, so the inner bytes round-trip exactly. (IAC-doubling is
        // defensive and a no-op for valid UTF-8.)
        let json = #"Char.Vitals {"hp":1234,"mana":900,"moves":500}"#
        let bytes = GMCPMessage.encode(payload: json)
        let inner = Array(bytes[3..<(bytes.count - 2)])
        #expect(inner == Array(json.utf8))
        #expect(!inner.contains(TelnetCommand.iac))
    }

    @Test("Handshake announces support for Char, Comm, Room and requests state")
    func handshakeContents() {
        let packets = GMCPMessage.aardwolfHandshake(clientVersion: "9.9.9")
        let payloads = packets.map { packet -> String in
            String(decoding: packet[3..<(packet.count - 2)], as: UTF8.self)
        }
        #expect(payloads.contains { $0.contains("Core.Hello") && $0.contains("9.9.9") })
        #expect(payloads.contains { $0.contains(#"Core.Supports.Set [ "Char 1", "Comm 1", "Room 1" ]"#) })
        #expect(payloads.contains("request char"))
        #expect(payloads.contains("rawcolor on"))
    }
}
