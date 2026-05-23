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

    @Test("With echo on, a channel line passes through; with echo off, it's gagged")
    func echoToggle() {
        var plugin = ChatEcho()
        _ = plugin.onGMCP(package: "comm.channel", json: channel("Homer chats hi", player: "Homer"))
        // Echo defaults on.
        #expect(plugin.onLine(line("Homer chats hi")).gag == false)

        _ = plugin.handleCommand("chats echo off")
        _ = plugin.onGMCP(package: "comm.channel", json: channel("Homer chats hi", player: "Homer"))
        #expect(plugin.onLine(line("Homer chats hi")).gag == true)
    }

    @Test("A non-channel line is never gagged")
    func nonChannelUntouched() {
        var plugin = ChatEcho()
        _ = plugin.handleCommand("chats echo off")
        #expect(plugin.onLine(line("You hit the goblin.")).gag == false)
    }

    @Test("Muting a player gags their channel line; others pass")
    func mutePlayer() {
        var plugin = ChatEcho()
        _ = plugin.handleCommand("chats mute homer")
        _ = plugin.onGMCP(package: "comm.channel", json: channel("Homer chats hi", player: "Homer"))
        _ = plugin.onGMCP(package: "comm.channel", json: channel("Bob chats yo", player: "Bob"))
        #expect(plugin.disposition(for: line("Homer chats hi"), now: Date()).gag == true)
        #expect(plugin.disposition(for: line("Bob chats yo"), now: Date()).gag == false)
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
