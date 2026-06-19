import Foundation
@testable import MudCore
import Testing

@Suite("GMCPStateStore — pending invitations")
struct GroupInviteStoreTests {
    @Test("An invite event adds a pending invitation")
    func addsInvite() async {
        let store = GMCPStateStore()
        await store.applyInviteEvent(.invited(inviter: "Bitako", groupName: "tako truck"))
        let invites = await store.state.pendingInvites
        #expect(invites == [GroupInvite(inviter: "Bitako", groupName: "tako truck")])
    }

    @Test("A cancel event removes the matching invite (case-insensitive)")
    func cancelRemovesInvite() async {
        let store = GMCPStateStore()
        await store.applyInviteEvent(.invited(inviter: "Bitako", groupName: "tako truck"))
        await store.applyInviteEvent(.cancelled(inviter: "bitako"))
        #expect(await store.state.pendingInvites.isEmpty)
    }

    @Test("A re-invite from the same player replaces the old entry (no duplicate)")
    func reinviteReplaces() async {
        let store = GMCPStateStore()
        await store.applyInviteEvent(.invited(inviter: "Bitako", groupName: "old name"))
        await store.applyInviteEvent(.invited(inviter: "Bitako", groupName: "tako truck"))
        let invites = await store.state.pendingInvites
        #expect(invites == [GroupInvite(inviter: "Bitako", groupName: "tako truck")])
    }

    @Test("Joining a group clears the pending invite from its leader")
    func joinClearsLeaderInvite() async {
        let store = GMCPStateStore()
        await store.applyInviteEvent(.invited(inviter: "Bitako", groupName: "tako truck"))
        let members = #"[{"name":"Bitako"},{"name":"Rodarvus"}]"#
        let group = GMCPMessage(
            package: "group",
            json: #"{"groupname":"tako truck","leader":"Bitako","members":\#(members)}"#
        )
        #expect(await store.apply(group))
        #expect(await store.state.pendingInvites.isEmpty)
        #expect(await store.state.group?.isGrouped == true)
    }

    @Test("reset() clears pending invitations")
    func resetClearsInvites() async {
        let store = GMCPStateStore()
        await store.applyInviteEvent(.invited(inviter: "Bitako", groupName: "tako truck"))
        await store.reset()
        #expect(await store.state.pendingInvites.isEmpty)
    }
}
