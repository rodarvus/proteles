import Foundation
@testable import MudCore
import Testing

@Suite("GroupInviteEvent — parsing")
struct GroupInviteParseTests {
    @Test("The live invite line parses into inviter + group name")
    func parsesLiveInvite() {
        // Verbatim from session-20260618-170947 (Bitako's invite to Rodarvus).
        let line = "Bitako has invited you to join group: tako truck."
        #expect(GroupInviteEvent.parse(line) == .invited(inviter: "Bitako", groupName: "tako truck"))
    }

    @Test("A one-word group name parses")
    func parsesSingleWordGroup() {
        #expect(
            GroupInviteEvent.parse("Sath has invited you to join group: raiders.")
                == .invited(inviter: "Sath", groupName: "raiders")
        )
    }

    @Test("Every reference cancel/decline line retracts the inviter's invite")
    func parsesAllCancelForms() {
        let cancels: [(String, String)] = [
            ("Bitako has cancelled your invitation to join group: tako truck.", "Bitako"),
            ("You have declined the group invitation from Bitako.", "Bitako"),
            ("You have no invitation outstanding from Bitako.", "Bitako"),
            ("Your group invite from Bitako is cancelled because the group has been disbanded.", "Bitako"),
            ("Your group invitation from Bitako is cancelled because Artou has left that group.", "Bitako"),
            ("Your group invitation from Bitako is cancelled because Artou has left the game.", "Bitako")
        ]
        for (line, inviter) in cancels {
            #expect(GroupInviteEvent.parse(line) == .cancelled(inviter: inviter), "failed: \(line)")
        }
    }

    @Test("Unrelated lines (incl. other 'group' chatter) don't parse as invites")
    func ignoresUnrelatedLines() {
        let nonInvites = [
            "Bitako (Champion of Loyalty) tells the CLAN: 'going to accept the invite or wut?'",
            "(Group) Bitako: 'you know what area'",
            "You have joined the group: tako truck.",
            "You start to follow Bitako.",
            "[ Violin  Music ] T:9 Invite Tiana . <-)light(->",
            ""
        ]
        for line in nonInvites {
            #expect(GroupInviteEvent.parse(line) == nil, "unexpectedly parsed: \(line)")
        }
    }

    @Test("Leading/trailing whitespace is tolerated")
    func toleratesWhitespace() {
        #expect(
            GroupInviteEvent.parse("  Bitako has invited you to join group: tako truck.  ")
                == .invited(inviter: "Bitako", groupName: "tako truck")
        )
    }
}
