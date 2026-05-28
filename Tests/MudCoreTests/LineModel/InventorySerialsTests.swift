import Foundation
@testable import MudCore
import Testing

@Suite("InventorySerials — parse + group + render invdata rows")
struct InventorySerialsTests {
    @Test("Parses a standard invdata row (id, flags, name, level)")
    func parseRow() {
        let item = InventorySerials.parseRow("123456,MG,a glowing sword,150,0,0,0,0")
        #expect(item == InventorySerials.Item(id: "123456", flags: "MG", name: "a glowing sword", level: 150))
    }

    @Test("Tolerates leading whitespace (keyring/vault rows) + empty flags")
    func parseWhitespaceAndNoFlags() {
        let item = InventorySerials.parseRow("   789,,a brass key,1,0,0,0,0")
        #expect(item?.id == "789")
        #expect(item?.flags.isEmpty == true)
        #expect(item?.name == "a brass key")
    }

    @Test("A non-data line returns nil")
    func parseNonRow() {
        #expect(InventorySerials.parseRow("You are carrying:") == nil)
        #expect(InventorySerials.parseRow("") == nil)
    }

    @Test("Identical items group, preserving order + collecting serials")
    func grouping() {
        let rows = [
            "1,M,a potion,10,0,0,0,0",
            "2,M,a potion,10,0,0,0,0",
            "3,,a torch,5,0,0,0,0",
            "4,M,a potion,10,0,0,0,0"
        ].compactMap(InventorySerials.parseRow)
        let groups = InventorySerials.group(rows)
        #expect(groups.count == 2)
        #expect(groups[0].name == "a potion")
        #expect(groups[0].ids == ["1", "2", "4"]) // first-seen order preserved
        #expect(groups[0].count == 3)
        #expect(groups[1].name == "a torch")
        #expect(groups[1].count == 1)
    }

    @Test("Render shows count, serials, and level; >3 ids collapse to 'many'")
    func render() {
        let single = InventorySerials.Group(flags: "", name: "a torch", level: 5, ids: ["3"])
        let line = InventorySerials.renderGroup(single)
        #expect(line.contains("a torch"))
        #expect(line.contains("[3]"))
        #expect(line.contains("@G5@W")) // level

        let many = InventorySerials.Group(
            flags: "M", name: "a potion", level: 10, ids: ["1", "2", "4", "9"]
        )
        let line2 = InventorySerials.renderGroup(many)
        #expect(line2.contains("@W( 4) @w")) // count badge when >1
        #expect(line2.contains("[many]")) // >3 serials collapse
        #expect(line2.contains("@B(M)@w")) // magic flag → @B
    }

    @Test("render(rows:) parses, groups, and renders end to end")
    func renderAll() {
        let lines = InventorySerials.render(rows: [
            "1,M,a potion,10,0,0,0,0",
            "2,M,a potion,10,0,0,0,0",
            "not a row"
        ])
        #expect(lines.count == 1)
        #expect(lines[0].contains("a potion"))
        #expect(lines[0].contains("[1,2]"))
    }
}
