@testable import MudCore
import Testing

/// `SessionController.isAardwolfTagLine` decides which lines the opt-in tag gag
/// withholds. It must match ONLY the telnet-102 tagged-output grammar
/// (`{tag}`/`{/tag}`, lowercase identifier, no internal spaces) and never real
/// game prose — the gag is display-only but must not hide content.
@Suite("SessionController — Aardwolf tag-line detection")
struct AardwolfTagLineTests {
    @Test("matches real tagged-output markers")
    func matchesTags() {
        #expect(SessionController.isAardwolfTagLine("{rname}A Light Provisions Room (G)"))
        #expect(SessionController.isAardwolfTagLine("{coords}0,30,20"))
        #expect(SessionController.isAardwolfTagLine("{invdata}"))
        #expect(SessionController.isAardwolfTagLine("{/invdata}"))
        #expect(SessionController.isAardwolfTagLine("{spellheaders}"))
        #expect(SessionController.isAardwolfTagLine("{/roomchars}"))
        #expect(SessionController.isAardwolfTagLine("{exits}north, east"))
    }

    @Test("never matches game prose, says/tells, or channels")
    func ignoresProse() {
        #expect(!SessionController.isAardwolfTagLine("You say '{hi}'"))
        #expect(!SessionController.isAardwolfTagLine("[Newbie] Bob: how do {braces} work?"))
        #expect(!SessionController.isAardwolfTagLine("A goblin arrives from the north."))
        #expect(!SessionController.isAardwolfTagLine("You found a {special} item."))
        #expect(!SessionController.isAardwolfTagLine(""))
    }

    @Test("rejects near-misses: spaces, caps, no close, empty tag")
    func rejectsNearMisses() {
        // dinv's fence marker: leading space + uppercase → not a tag (and dinv
        // gags it itself anyway).
        #expect(!SessionController.isAardwolfTagLine("{ DINV fence 16 }"))
        #expect(!SessionController.isAardwolfTagLine("{MAPSTART}")) // uppercase
        #expect(!SessionController.isAardwolfTagLine("{rname")) // no closing brace
        #expect(!SessionController.isAardwolfTagLine("{}")) // empty tag
        #expect(!SessionController.isAardwolfTagLine("{1bad}")) // digit-first identifier
        #expect(!SessionController.isAardwolfTagLine("text {rname} mid-line")) // not at start
    }
}
