import Foundation
@testable import MudCore
import Testing

@Suite("ChatEcho — channel echo + player mute")
struct ChatEchoTests {
    private func line(_ text: String) -> Line {
        Line(id: LineID(1), text: text)
    }

    /// Feed a comm.channel GMCP so the line is recognised as channel chatter.
    private func channel(_ msg: String, player: String) -> String {
        #"{"chan":"chat","msg":"\#(msg)","player":"\#(player)"}"#
    }

    @Test("Echo on renders the channel from GMCP and gags the inline dup; echo off suppresses the echo")
    func echoToggle() {
        var plugin = ChatEcho()
        // Echo defaults on: GMCP emits a colored echo; the raw inline dup is gagged.
        let onEffects = plugin.onGMCP(
            package: "comm.channel",
            json: channel("Homer chats hi", player: "Homer")
        )
        #expect(onEffects == [.echoAard("Homer chats hi")])
        #expect(plugin.onLine(line("Homer chats hi")).gag == true)

        // Echo off: no echo emitted, inline still gagged (hidden from main).
        _ = plugin.handleCommand("chats echo off")
        let offEffects = plugin.onGMCP(
            package: "comm.channel",
            json: channel("Homer chats hi", player: "Homer")
        )
        #expect(offEffects.isEmpty)
        #expect(plugin.onLine(line("Homer chats hi")).gag == true)
    }

    @Test("A caught tell (comm.channel only, no inline line) is echoed so it isn't lost")
    func caughtTellEchoed() {
        var plugin = ChatEcho()
        // catchtells: the tell arrives via comm.channel but the server withholds
        // the inline copy — the GMCP echo is the only way it reaches main.
        let effects = plugin.onGMCP(
            package: "comm.channel",
            json: channel("Bob tells you 'test'", player: "Bob")
        )
        #expect(effects == [.echoAard("Bob tells you 'test'")])
    }

    @Test("A non-channel line is never gagged")
    func nonChannelUntouched() {
        var plugin = ChatEcho()
        _ = plugin.handleCommand("chats echo off")
        #expect(plugin.onLine(line("You hit the goblin.")).gag == false)
    }

    @Test("A muted speaker isn't echoed; an unmuted one is; both inline dups are gagged")
    func mutePlayer() {
        var plugin = ChatEcho()
        _ = plugin.handleCommand("chats mute homer")
        let homer = plugin.onGMCP(package: "comm.channel", json: channel("Homer chats hi", player: "Homer"))
        let bob = plugin.onGMCP(package: "comm.channel", json: channel("Bob chats yo", player: "Bob"))
        #expect(homer.isEmpty) // muted → no echo (hidden)
        #expect(bob == [.echoAard("Bob chats yo")]) // unmuted → colored echo
        // Both raw inline dups are gagged (the echo, or its suppression, stands in).
        #expect(plugin.disposition(for: line("Homer chats hi"), now: Date()).gag == true)
        #expect(plugin.disposition(for: line("Bob chats yo"), now: Date()).gag == true)
    }

    @Test("A timed mute expires")
    func timedMuteExpires() {
        var plugin = ChatEcho()
        let now = Date()
        _ = plugin.handleCommand("chats mute homer 5") // 5 minutes
        #expect(plugin.isMuted("Homer", now: now) == true)
        #expect(plugin.isMuted("Homer", now: now.addingTimeInterval(4 * 60)) == true)
        #expect(plugin.isMuted("Homer", now: now.addingTimeInterval(6 * 60)) == false) // expired
    }

    @Test("unmute and clear remove mutes")
    func unmuteAndClear() {
        var plugin = ChatEcho()
        _ = plugin.handleCommand("chats mute homer")
        _ = plugin.handleCommand("chats unmute homer")
        #expect(plugin.isMuted("homer", now: Date()) == false)

        _ = plugin.handleCommand("chats mute a")
        _ = plugin.handleCommand("chats mute b")
        _ = plugin.handleCommand("chats mute clear")
        #expect(plugin.isMuted("a", now: Date()) == false)
        #expect(plugin.isMuted("b", now: Date()) == false)
    }

    @Test("Commands persist; unrelated input passes through")
    func commandsAndPassthrough() {
        var plugin = ChatEcho()
        let pluginID = plugin.metadata.id
        let effects = plugin.handleCommand("chats echo off")
        #expect(effects?.contains(.persistPluginState(id: pluginID)) == true)
        #expect(plugin.handleCommand("look") == nil)
        #expect(plugin.handleCommand("chat hello") == nil) // the real channel command
    }

    @Test("checkIfMuted call surface answers mutes, re-validating expiry (#55)")
    func checkIfMutedCallSurface() {
        var plugin = ChatEcho()
        _ = plugin.handleCommand("chats mute Villain")
        #expect(plugin.call("checkIfMuted", [.string("Villain")]) == [.boolean(true)])
        #expect(plugin.call("checkIfMuted", [.string("villain")]) == [.boolean(true)])
        #expect(plugin.call("checkIfMuted", [.string("Friend")]) == [.boolean(false)])
        // Unknown functions and missing arguments answer nothing.
        #expect(plugin.call("somethingElse", [.string("Villain")]).isEmpty)
        #expect(plugin.call("checkIfMuted", []).isEmpty)

        // A timed mute that has expired answers false at call time.
        _ = plugin.handleCommand("chats mute Brief 0")
        #expect(plugin.call("checkIfMuted", [.string("Brief")]) == [.boolean(false)])
    }

    @Test("State round-trips through persistentState/restore")
    func persistence() {
        var source = ChatEcho()
        _ = source.handleCommand("chats echo off")
        _ = source.handleCommand("chats mute villain")
        guard let data = source.persistentState else { Issue.record("no state"); return }

        var restored = ChatEcho()
        restored.restore(from: data)
        _ = restored.onGMCP(package: "comm.channel", json: channel("Villain chats boo", player: "Villain"))
        #expect(restored.disposition(for: line("Villain chats boo"), now: Date()).gag == true)
    }
}
