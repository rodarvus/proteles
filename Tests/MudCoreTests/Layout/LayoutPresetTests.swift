@testable import MudCore
import Testing

@Suite("LayoutPreset — upsert / remove rules")
struct LayoutPresetTests {
    private func preset(_ name: String) -> LayoutPreset {
        LayoutPreset(name: name, layout: .standard, floating: [.asciiMap])
    }

    @Test("Upsert appends a new preset and keeps the list name-sorted")
    func upsertSorts() {
        let list = [preset("Combat")].upserting(preset("Alpha"))
        #expect(list.map(\.name) == ["Alpha", "Combat"])
    }

    @Test("Upsert overwrites a same-name preset (case-insensitive), no duplicate")
    func upsertOverwrites() {
        var list = [preset("Combat")]
        list = list.upserting(LayoutPreset(name: "combat", layout: .outputOnly, floating: []))
        #expect(list.count == 1)
        #expect(list[0].name == "combat", "the new (trimmed) name replaces the old")
        #expect(list[0].layout == .outputOnly)
    }

    @Test("A blank name is rejected")
    func blankRejected() {
        #expect([preset("Keep")].upserting(preset("   ")).map(\.name) == ["Keep"])
    }

    @Test("Names are trimmed on save")
    func trims() {
        #expect([LayoutPreset]().upserting(preset("  Hunt  "))[0].name == "Hunt")
    }

    @Test("Remove deletes by case-insensitive name")
    func removes() {
        #expect([preset("Combat")].removing(named: "COMBAT").isEmpty)
    }
}
