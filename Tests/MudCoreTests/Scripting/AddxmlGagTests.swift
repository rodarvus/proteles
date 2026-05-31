import Foundation
@testable import MudCore
import Testing

/// The Message Gagger plugin builds its gag triggers with
/// `addxml.trigger { match = "...", regexp = false, omit_from_output = true, … }`
/// from `OnPluginInstall`. This reproduces that exact shape and checks the line
/// is actually gagged — pinning whether the addxml → AddTriggerEx → engine path
/// honours `omit_from_output` for a literal (non-regex) trigger.
@Suite("addxml gag triggers")
struct AddxmlGagTests {
    private let gagPlugin = """
    <muclient>
    <plugin id="com.test.gag" name="Gag"/>
    <script><![CDATA[
    require "addxml"
    function OnPluginInstall()
      addxml.trigger {
        match = "You feel weaker.",
        regexp = false,
        sequence = 50,
        enabled = true,
        omit_from_output = true,
        group = "message_gagger",
        send_to = 12,
        send = "gagged = (gagged or 0) + 1",
      }
    end
    ]]></script>
    </muclient>
    """

    @Test("an addxml literal omit_from_output trigger gags the matching line")
    func gagsLiteralLine() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: gagPlugin))

        let disposition = await engine.process(line: "You feel weaker.")
        #expect(disposition.gag, "addxml omit_from_output trigger did not gag the line")
        // A non-matching line is untouched.
        let other = await engine.process(line: "You feel stronger.")
        #expect(!other.gag)
    }

    /// The real Message Gagger reads its patterns from a `messages_to_gag.txt`
    /// the user maintains — often with Windows CRLF endings. Our sandboxed
    /// `io.lines` must read them like MUSHclient's text mode (no trailing CR),
    /// else every literal gag pattern keeps a stray `\r` and never matches the
    /// CR-less MUD line. This drives the real gag chain end-to-end over a CRLF
    /// file: read patterns via io.lines → addxml gag triggers → match.
    @Test("a gag pattern read from a CRLF file still matches (io.lines strips CR)")
    func crlfGagFileStillGags() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gag-crlf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // CRLF line endings, as a Windows-edited gag list would have.
        try "You feel weaker.\r\nYou slowly float to the ground.\r\n"
            .write(to: dir.appendingPathComponent("gag.txt"), atomically: true, encoding: .utf8)

        let plugin = """
        <muclient>
        <plugin id="com.test.gagfile" name="GagFile"/>
        <script><![CDATA[
        require "addxml"
        function OnPluginInstall()
          for line in io.lines(GetInfo(56) .. "gag.txt") do
            if line ~= "" then
              addxml.trigger { match = line, regexp = false, enabled = true,
                omit_from_output = true, send_to = 12, send = "x = 1" }
            end
          end
        end
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        await engine.setSQLiteDirectory(dir.path)
        let context = PluginContext(
            pluginID: "com.test.gagfile",
            pluginName: "GagFile",
            pluginDirectory: dir.path + "/",
            worldDirectory: dir.path + "/",
            appDirectory: dir.path + "/",
            stateDirectory: dir.path + "/"
        )
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin), context: context)

        #expect(await engine.process(line: "You feel weaker.").gag, "CRLF gag pattern didn't match")
        #expect(await engine.process(line: "You slowly float to the ground.").gag)
    }
}
