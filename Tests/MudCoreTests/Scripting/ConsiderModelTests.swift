import Foundation
@testable import MudCore
import Testing

@Suite("ConsiderModel — parsing + state machine")
struct ConsiderModelTests {
    /// Run a `consider all` capture over `lines` and return the model.
    private func consider(_ lines: [String], zone: String? = nil) -> ConsiderModel {
        var model = ConsiderModel()
        model.beginConsider()
        for line in lines {
            model.ingestLine(line, zone: zone)
        }
        model.endConsider()
        return model
    }

    // MARK: - Tier parsing

    @Test("Each tier line parses into a mob with the plugin's colour + range")
    func tiersParse() {
        let model = consider([
            "a goblin looks a little worried about the idea.",
            "the ancient dragon would dance on your grave!",
            "Best run away from a fierce orc while you can!",
            "You would stomp a weakling into the ground."
        ])
        #expect(model.mobs.count == 4)
        #expect(model.mobs[0].colour == "chartreuse")
        #expect(model.mobs[0].rangeLabel == "-2 to -4")
        #expect(model.mobs[0].keyword == "goblin")
        #expect(model.mobs[1].colour == "darkmagenta")
        #expect(model.mobs[1].rangeLabel == "+31 to +41")
        #expect(model.mobs[1].keyword == "ancient dragon")
        #expect(model.mobs[2].colour == "tomato")
        #expect(model.mobs[2].keyword == "fierce orc")
        #expect(model.mobs[3].colour == "gray")
        #expect(model.mobs[3].rangeLabel == "-20 and below")
    }

    @Test("Leading aura flags are captured, name stays clean")
    func auraFlagsCaptured() {
        let model = consider(["(Red Aura) a temple guard should be a fair fight!"])
        #expect(model.mobs.count == 1)
        #expect(model.mobs[0].rawFlags == "(Red Aura)")
        #expect(model.mobs[0].name == "a temple guard")
        #expect(model.mobs[0].keyword == "temple guard")
    }

    @Test("Consider lines outside a run are ignored")
    func ignoredOutsideRun() {
        var model = ConsiderModel()
        model.ingestLine("a goblin should be a fair fight!")
        #expect(model.mobs.isEmpty)
    }

    @Test("A new run replaces the previous list on its first matched line")
    func runReplacesList() {
        var model = consider(["a goblin should be a fair fight!"])
        #expect(model.mobs.count == 1)
        model.beginConsider()
        model.ingestLine("an orc should be a fair fight!")
        model.ingestLine("a rat should be a fair fight!")
        model.endConsider()
        #expect(model.mobs.count == 2)
        #expect(model.mobs.map(\.name) == ["an orc", "a rat"])
    }

    // MARK: - Duplicate indexing

    @Test("Duplicate names get sequential indices")
    func duplicateIndices() {
        let model = consider(Array(repeating: "a goblin should be a fair fight!", count: 3))
        #expect(model.mobs.map(\.index) == [1, 2, 3])
    }

    // MARK: - Kill / leave / arrive transitions

    @Test("A kill marks the first matching mob dead and renumbers the rest")
    func killRenumbers() {
        var model = consider(Array(repeating: "a goblin should be a fair fight!", count: 2))
        model.ingestLine("a goblin is DEAD!!")
        #expect(model.mobs[0].dead)
        #expect(model.mobs[0].pct == 0)
        #expect(model.mobs[1].index == 1) // the survivor renumbers to 1
    }

    @Test("A mob leaving marks the last living match as left")
    func leaveMarksLast() {
        var model = consider(Array(repeating: "a goblin should be a fair fight!", count: 2))
        model.ingestLine("a goblin leaves north.")
        #expect(model.mobs[1].left)
        #expect(!model.mobs[0].left)
        #expect(model.mobs[0].index == 1)
    }

    @Test("A mob arriving prepends, marked arrived until considered")
    func arrivePrepends() {
        var model = consider(["a goblin should be a fair fight!"])
        #expect(model.ingestLine("A troll warrior appears in the room.") == .mobArrived("A troll warrior"))
        #expect(model.mobs.count == 2)
        #expect(model.mobs[0].name == "A troll warrior")
        #expect(model.mobs[0].came)
        #expect(model.mobs[0].detail == "arrived")
    }

    // Every movement line below is from a recording.

    @Test("a mob on the list leaves by any verb; where it went is shown")
    func leaveAnyVerb() {
        var model = consider([
            "(R) A wetland spite snickers nervously.",
            "(G) A radiant ibis snickers nervously."
        ])
        #expect(model.ingestLine("A radiant ibis flutters south.") == .mobLeft("A radiant ibis"))
        #expect(model.mobs[1].left)
        #expect(model.mobs[1].detail == "left south")
        #expect(!model.mobs[1].dead)
        #expect(!model.mobs[0].left)
    }

    @Test("a line shaped like a departure, naming no listed mob, is ignored")
    func leaveUnlisted() {
        var model = consider(["(G) A radiant ibis snickers nervously."])
        #expect(model.ingestLine("Your mental barrier breaks down.") == .ignored)
        #expect(model.ingestLine("A red-bellied lieweaver glides east.") == .ignored)
        #expect(!model.mobs[0].left)
    }

    @Test("a fled mob says so")
    func fled() {
        var model = consider(["A giant bat should be a fair fight!"])
        #expect(model.ingestLine("A giant bat has fled!") == .mobFled("A giant bat"))
        #expect(model.mobs[0].detail == "fled")
    }

    @Test("arrivals by any verb; flags dropped; a description's 'You see' dropped")
    func arrivalShapes() {
        let arrivals = [
            "A daystar swan flutters in from the west.",
            "(F)(R) A plume of smoke and ash billows in from the east.",
            "You see a kobold knight charging in from the west.",
            "A wolf arrives from the south."
        ].map(ConsiderMovement.arrival)
        #expect(arrivals == ["A daystar swan", "A plume of smoke and ash", "A kobold knight", "A wolf"])
    }

    @Test("a player's thunderclap and other 'from' lines aren't arrivals")
    func notArrivals() {
        var model = consider(["a goblin should be a fair fight!"])
        #expect(model.ingestLine("With a thunderclap, Turnus appears in the room.") == .ignored)
        #expect(ConsiderMovement.arrival("A moderate wind blows from the west.") == nil)
        #expect(ConsiderMovement.arrival("(R) A sand dollar appears to have washed in from the sea.") == nil)
        #expect(model.mobs.count == 1)
    }

    @Test("Departures/arrivals in an ignored zone are dropped")
    func ignoredZone() {
        var model = consider(["a goblin should be a fair fight!"], zone: "manor")
        model.ignoredZones = ["manor"]
        model.ingestLine("a goblin leaves north.", zone: "manor")
        #expect(!model.mobs[0].left)
    }

    // MARK: - Single attack formatting

    @Test("Attack command formats per execute mode and marks attacked")
    func attackFormatting() {
        var model = consider(["a goblin should be a fair fight!"])
        #expect(model.attackCommand(position: 1, command: "kill", mode: .skill) == "kill 1.'goblin'")
        #expect(model.mobs[0].attacked)
        #expect(model.attackCommand(position: 1, command: "cast acid", mode: .cast) == "cast acid '1.goblin'")
        #expect(model.attackCommand(position: 1, command: "protect", mode: .pro) == "protect 1 goblin")
        #expect(model.attackCommand(position: 99, command: "kill", mode: .skill) == nil)
    }

    // MARK: - Batch (conwall)

    @Test("Batch caps at maxRoomCount and attacks in reverse order")
    func batchReverseAndCap() {
        var model = consider(Array(repeating: "a goblin should be a fair fight!", count: 6))
        let plan = model.planBatch(options: ConsiderBatchOptions(), defaultCommand: "kill", mode: .skill)
        guard case .targets(let commands) = plan else {
            Issue.record("expected .targets, got \(plan)")
            return
        }
        #expect(commands.count == 5) // default maxRoomCount
        #expect(commands.first == "kill 6.'goblin'") // highest index first (reverse)
        #expect(!model.mobs[0].attacked) // the untouched first mob
        #expect(model.mobs[5].attacked)
    }

    @Test("Batch skips mobs outside the level window")
    func batchSkipsOutOfRange() {
        var model = consider([
            "a goblin should be a fair fight!", // -1 to +1, in range
            "the ancient dragon would dance on your grave!" // +31..+41, out of range
        ])
        let plan = model.planBatch(options: ConsiderBatchOptions(), defaultCommand: "kill", mode: .skill)
        guard case .targets(let commands) = plan else {
            Issue.record("expected .targets, got \(plan)")
            return
        }
        #expect(commands.count == 1)
        #expect(commands[0].contains("goblin"))
        #expect(!model.mobs[1].attacked) // the dragon is skipped
    }

    @Test("Batch fires the AoE shortcut when the count fits the window")
    func batchAoE() {
        var model = consider(Array(repeating: "a goblin should be a fair fight!", count: 3))
        var options = ConsiderBatchOptions()
        options.maxAoeCount = 5
        options.minAoeCount = 2
        let plan = model.planBatch(options: options, defaultCommand: "kill", mode: .skill)
        #expect(plan == .aoe(commands: ["c ultrablast", "kill"]))
        let allAttacked = model.mobs.allSatisfy(\.attacked)
        #expect(allAttacked)
    }

    @Test("Batch on an empty list reports noMobs")
    func batchEmpty() {
        var model = ConsiderModel()
        #expect(model
            .planBatch(options: ConsiderBatchOptions(), defaultCommand: "kill", mode: .skill) == .noMobs)
    }

    @Test("Alignment auto-skip derives skip flags from the player's align")
    func autoAlign() {
        var options = ConsiderBatchOptions()
        options.skipAlignAuto = true
        ConsiderModel.autoAlign(&options, playerAlign: -800)
        #expect(options.skipEvil)
        #expect(!options.skipGood)
        ConsiderModel.autoAlign(&options, playerAlign: 900)
        #expect(options.skipGood)
        #expect(!options.skipEvil)
    }
}

@Suite("ConsiderTiers — ranges + name cleanup")
struct ConsiderTiersTests {
    @Test("Range bounds parse the way ShouldSkipMob does")
    func rangeBounds() {
        #expect(ConsiderTier.parseRangeBounds("-2 to -4") == -4...(-2))
        #expect(ConsiderTier.parseRangeBounds("+16 to +20") == 16...20)
        #expect(ConsiderTier.parseRangeBounds("-20 and below") == -300...(-20))
        #expect(ConsiderTier.parseRangeBounds("+51 and above") == 50...300)
    }

    @Test("Stripname removes articles, prepositions, and punctuation")
    func nameCleanup() {
        #expect(ConsiderNameCleanup.strip("a goblin") == "goblin")
        #expect(ConsiderNameCleanup.strip("the High Priest of Light") == "High Priest Light")
        #expect(ConsiderNameCleanup.strip("an ancient, cruel beast") == "ancient cruel beast")
    }

    @Test("Citadel titles are trimmed only in that zone")
    func citadelTitles() {
        #expect(ConsiderNameCleanup.strip("Bob prince of darkness", zone: "citadel") == "Bob")
        #expect(ConsiderNameCleanup
            .strip("Bob prince of darkness", zone: "midgaard") == "Bob prince darkness")
    }
}
