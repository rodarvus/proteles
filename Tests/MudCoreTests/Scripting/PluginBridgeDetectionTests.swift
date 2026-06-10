import Foundation
@testable import MudCore
import Testing

/// Shim plugins must be able to *detect* and *call into* the natively-hosted
/// S&D (and friends). `IsPluginInstalled` used to answer true only for the
/// caller's own id, so a plugin's campaign mode reported "Search-and-Destroy
/// not installed" even with the host attached (live report, 2026-06-10) —
/// and `CallPlugin(<S&D id>, fn)` fell through to a no-op.
@Suite("shim → native-host plugin detection + calls")
struct PluginBridgeDetectionTests {
    private let probePlugin = """
    <muclient>
    <plugin id="com.test.bridge" name="Bridge"/>
    <aliases>
    <alias match="^probe installed$" enabled="y" regexp="y" send_to="12" script="probe_installed"/>
    <alias match="^probe call$" enabled="y" regexp="y" send_to="12" script="probe_call"/>
    </aliases>
    <script><![CDATA[
    function probe_installed()
      Note("snd=" .. tostring(IsPluginInstalled("30000000537461726C696E67"))
        .. " gmcp=" .. tostring(IsPluginInstalled("3e7dedbe37e44942dd46d264"))
        .. " self=" .. tostring(IsPluginInstalled("com.test.bridge"))
        .. " other=" .. tostring(IsPluginInstalled("ffffffffffffffffffffffff")))
    end
    function probe_call()
      CallPlugin("30000000537461726C696E67", "do_cp_check")
    end
    ]]></script>
    </muclient>
    """

    /// The probe's `Note(...)` surfaces as an `.echo` effect in the shim.
    private func noteText(_ effects: [ScriptEffect]) -> String? {
        for effect in effects {
            if case .echo(let text) = effect { return text }
            if case .note(let text, _, _) = effect { return text }
        }
        return nil
    }

    @Test("IsPluginInstalled: self + unconditional bridges true; S&D follows attachment")
    func installedAnswers() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))

        var note = await noteText(engine.expandInput("probe installed"))
        #expect(note == "snd=false gmcp=true self=true other=false")

        // The session marks S&D bridged when the host attaches.
        await engine.setBridgedPlugin(SearchAndDestroyHost.pluginID, installed: true)
        note = await noteText(engine.expandInput("probe installed"))
        #expect(note == "snd=true gmcp=true self=true other=false")

        // …and un-bridged when a world reload drops it (D-107 disable).
        await engine.setBridgedPlugin(SearchAndDestroyHost.pluginID, installed: false)
        note = await noteText(engine.expandInput("probe installed"))
        #expect(note == "snd=false gmcp=true self=true other=false")
    }

    @Test("CallPlugin(<S&D id>, fn) bridges to a callSearchAndDestroy effect")
    func callBridges() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))
        let effects = await engine.expandInput("probe call")
        #expect(effects.contains(.callSearchAndDestroy(function: "do_cp_check", args: [])))
    }

    @Test("the S&D host runs a bridged call (and ignores non-identifiers)")
    func hostRunsCall() async throws {
        guard SnDFixture.install() else { return }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-call-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try SearchAndDestroyHost()
        await host.configure(directory: dir.path)
        try await host.load()

        // A real S&D global: InfoNote produces output through the call.
        let effects = await host.call("InfoNote", args: ["bridged"])
        #expect(!effects.isEmpty, "InfoNote produced no effects: \(effects)")
        // Injection-shaped names are refused outright.
        let refused = await host.call("os.exit() --", args: [])
        #expect(refused.isEmpty)
    }
}
