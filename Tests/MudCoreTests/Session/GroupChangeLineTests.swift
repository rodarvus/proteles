@testable import MudCore
import Testing

@Suite("SessionController — group-change line detection")
struct GroupChangeLineTests {
    @Test("Recognises group join/leave/disband/leader lines")
    func recognisesChanges() {
        let yes = [
            "You have joined the group: Pup(Idle)Train.",
            "Rodarvus has joined the group.",
            "Tiana has left the group.",
            "Your group has been disbanded.",
            "Rodarvus is now the group leader.",
            "Kalista leaves the group.",
            "Rodarvus has been removed from the group."
        ]
        for line in yes {
            #expect(SessionController.isGroupChangeLine(line), "should match: \(line)")
        }
    }

    @Test("Ignores ordinary lines (incl. group chatter)")
    func ignoresOthers() {
        let no = [
            "You say 'hello'",
            "(Group) Rodarvus: 'repop in 4'", // chat on the group channel, not a change
            "A small dog wanders by.",
            "[ Exits: north east ]"
        ]
        for line in no {
            #expect(!SessionController.isGroupChangeLine(line), "should NOT match: \(line)")
        }
    }
}
