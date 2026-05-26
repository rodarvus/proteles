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
}
