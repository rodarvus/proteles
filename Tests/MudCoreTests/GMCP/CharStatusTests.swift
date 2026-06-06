@testable import MudCore
import Testing

@Suite("CharStatus — combat target")
struct CharStatusCombatTargetTests {
    @Test("In combat: returns the enemy name and health percent")
    func inCombat() {
        let status = CharStatus(level: 100, enemy: "a goblin", enemypct: 45)
        let target = status.combatTarget
        #expect(target?.name == "a goblin")
        #expect(target?.percent == 45)
    }

    @Test("Out of combat: empty enemy → nil (Aardwolf clears it to \"\")")
    func emptyEnemy() {
        #expect(CharStatus(level: 100, enemy: "", enemypct: 0).combatTarget == nil)
    }

    @Test("No enemy / no percent → nil")
    func missingFields() {
        #expect(CharStatus(level: 100).combatTarget == nil)
        #expect(CharStatus(level: 100, enemy: "a goblin", enemypct: nil).combatTarget == nil)
    }

    @Test("isSafeToInterrupt: blocks fighting/running/note-mode + active combat (#42)")
    func safeToInterruptGuard() {
        // Unsafe states (8 fighting, 12 running, 5 note-mode) → not safe.
        #expect(!CharStatus(level: 100, state: 8).isSafeToInterrupt)
        #expect(!CharStatus(level: 100, state: 12).isSafeToInterrupt)
        #expect(!CharStatus(level: 100, state: 5).isSafeToInterrupt)
        // Active combat target → not safe even if state is unknown.
        #expect(!CharStatus(level: 100, enemy: "an orc", enemypct: 40).isSafeToInterrupt)
        // Idle/standing (3) with no enemy → safe.
        #expect(CharStatus(level: 100, state: 3).isSafeToInterrupt)
        // Unknown state, no combat → falls back to safe.
        #expect(CharStatus(level: 100).isSafeToInterrupt)
    }
}
