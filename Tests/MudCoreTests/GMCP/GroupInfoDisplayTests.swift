import Foundation
@testable import MudCore
import Testing

@Suite("GroupInfo — display filter/sort + quest tag (#17)")
struct GroupInfoDisplayTests {
    private func member(
        _ name: String,
        hp: Int? = nil,
        mhp: Int? = nil,
        here: String? = nil,
        qs: String? = nil,
        qt: String? = nil
    ) -> GroupInfo.Member {
        GroupInfo.Member(name: name, info: .init(
            hp: hp.map(String.init),
            mhp: mhp.map(String.init),
            here: here,
            qt: qt,
            qs: qs
        ))
    }

    @Test("questTag: [Q] on quest, Q:NN from the timer, nil when no quest info")
    func questTag() {
        #expect(member("A", qs: "1").info?.questTag == "[Q]")
        #expect(member("B", qs: "0", qt: "7").info?.questTag == "Q:7")
        #expect(member("C", qt: "0").info?.questTag == nil) // 0 → nothing to show
        #expect(member("D").info?.questTag == nil)
    }

    @Test("roomOnly drops only members explicitly elsewhere (here == 0)")
    func roomOnlyFilter() {
        let group = GroupInfo(members: [
            member("Here", here: "1"),
            member("Away", here: "0"),
            member("Unknown") // no `here` → kept
        ])
        let names = group.displayMembers(roomOnly: true).map(\.name)
        #expect(names == ["Here", "Unknown"])
        // Without the filter, all three remain in order.
        #expect(group.displayMembers().map(\.name) == ["Here", "Away", "Unknown"])
    }

    @Test("mostHurt sorts by HP% ascending, stably; unknown HP sorts as healthy")
    func mostHurtSort() {
        let group = GroupInfo(members: [
            member("Full", hp: 100, mhp: 100), // 100%
            member("Half", hp: 50, mhp: 100), // 50%
            member("Crit", hp: 10, mhp: 100), // 10%
            member("NoVitals") // unknown → treated as full
        ])
        #expect(group.displayMembers(sort: .mostHurt).map(\.name) == ["Crit", "Half", "Full", "NoVitals"])
    }

    @Test("questGrouped puts on-quest members first, preserving order within")
    func questGroupedSort() {
        let group = GroupInfo(members: [
            member("X"),
            member("Q1", qs: "1"),
            member("Y"),
            member("Q2", qs: "1")
        ])
        #expect(group.displayMembers(sort: .questGrouped).map(\.name) == ["Q1", "Q2", "X", "Y"])
    }

    @Test("qt/qs survive a tolerant GMCP decode and are absent-safe")
    func decodeTolerant() throws {
        // A payload with qt/qs.
        let withQuest = #"{"name":"A","info":{"hp":"50","mhp":"100","qt":"3","qs":"1"}}"#
        let quester = try JSONDecoder().decode(GroupInfo.Member.self, from: Data(withQuest.utf8))
        #expect(quester.info?.qt == "3")
        #expect(quester.info?.onQuest == true)
        // A payload without them still decodes (older/ungrouped servers).
        let without = #"{"name":"B","info":{"hp":"50","mhp":"100"}}"#
        let plain = try JSONDecoder().decode(GroupInfo.Member.self, from: Data(without.utf8))
        #expect(plain.info?.qt == nil)
        #expect(plain.info?.onQuest == false)
    }
}
