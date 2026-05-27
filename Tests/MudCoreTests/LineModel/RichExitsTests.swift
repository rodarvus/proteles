import Foundation
@testable import MudCore
import Testing

@Suite("RichExits — detect + render clickable exit lines")
struct RichExitsTests {
    // MARK: - Detection

    @Test("The tagged exits line is recognised")
    func detectsTaggedLine() {
        #expect(RichExits.isTaggedExitsLine("{exits}[ Exits: north east ]"))
        #expect(RichExits.isTaggedExitsLine("{exits}[ Exits: none ]"))
    }

    @Test("Untagged or unrelated lines are not exits lines")
    func ignoresOtherLines() {
        #expect(!RichExits.isTaggedExitsLine("[ Exits: north east ]")) // no tag
        #expect(!RichExits.isTaggedExitsLine("You see a portal here."))
        #expect(!RichExits.isTaggedExitsLine("{exits}[ Exits: north east ")) // no closing ]
    }

    @Test("Tag-toggle confirmations are recognised for gagging")
    func detectsConfirmations() {
        #expect(RichExits.isTagConfirmation("Tag option exits turned ON"))
        #expect(RichExits.isTagConfirmation("Tag option exits turned OFF"))
        #expect(!RichExits.isTagConfirmation("Tag option channels turned ON"))
    }

    // MARK: - Cardinal extraction

    @Test("Cardinals come out in compass order with full-word labels")
    func cardinalOrdering() {
        let cardinals = RichExits.cardinals(fromExits: ["e": 200, "n": 100, "u": 300])
        #expect(cardinals.map(\.label) == ["north", "east", "up"])
        #expect(cardinals.map(\.command) == ["north", "east", "up"])
        #expect(cardinals.map(\.destination) == [100, 200, 300])
    }

    @Test("Invalid -1 destinations are skipped; nil exits give an empty list")
    func skipsInvalidExits() {
        #expect(RichExits.cardinals(fromExits: ["n": -1, "s": 50]).map(\.label) == ["south"])
        #expect(RichExits.cardinals(fromExits: nil).isEmpty)
    }

    @Test("Cardinal directions are distinguished from custom-exit commands")
    func cardinalPredicate() {
        #expect(RichExits.isCardinalDirection("n"))
        #expect(RichExits.isCardinalDirection("SW"))
        #expect(!RichExits.isCardinalDirection("enter portal"))
        #expect(!RichExits.isCardinalDirection("climb wall"))
    }

    // MARK: - Rendering

    private func render(
        _ cardinals: [RichExits.Cardinal],
        _ custom: [RichExits.CustomExit] = []
    ) -> Line {
        RichExits.render(cardinals: cardinals, customExits: custom, id: LineID(7), timestamp: Date())
    }

    @Test("Each cardinal renders as a sendCommand link with a destination hint")
    func cardinalLinks() {
        let line = render(RichExits.cardinals(fromExits: ["n": 1234, "e": 5678]))
        #expect(line.text == "[ Exits: north east ]")
        let links = line.runs.compactMap(\.link)
        #expect(links.contains(LineLink(action: .sendCommand("north"), hint: "moves to 1234")))
        #expect(links.contains(LineLink(action: .sendCommand("east"), hint: "moves to 5678")))
    }

    @Test("Custom exits append after cardinals; multi-word commands are quoted")
    func customExits() {
        let line = render(
            RichExits.cardinals(fromExits: ["n": 1]),
            [RichExits.CustomExit(command: "enter portal", destination: "9999")]
        )
        #expect(line.text == "[ Exits: north 'enter portal' ]")
        let link = line.runs.compactMap(\.link).first { $0.action == .sendCommand("enter portal") }
        #expect(link?.hint == "'enter portal' moves to 9999")
    }

    @Test("A room with no exits renders 'none'")
    func noExits() {
        #expect(render([]).text == "[ Exits: none ]")
    }

    @Test("The rendered line preserves the source id and is fully green")
    func styling() {
        let line = render(RichExits.cardinals(fromExits: ["n": 1]))
        #expect(line.id == LineID(7))
        #expect(line.runs.allSatisfy { $0.style.foreground == .named(.green) })
    }
}
