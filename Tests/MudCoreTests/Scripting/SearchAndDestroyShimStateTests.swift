import Foundation
@testable import MudCore
import Testing

/// The SYNCHRONOUS S&D read path. `CallPlugin(<S&D id>, fn, …)` from a shim
/// plugin is bridged as a fire-and-forget effect, so it can never return a
/// value — a campaign-driving plugin read `target_as_json` as nil and wrongly
/// concluded "no active campaign" while S&D was mid-hunt (live transcript,
/// 2026-06-10). The host now mirrors its shim-readable accessors into the
/// shim runtime (`__snd_state`) whenever they change; the shim's `CallPlugin`
/// answers reads from that mirror synchronously.
@Suite("S&D shim-state mirror — synchronous CallPlugin reads")
struct SearchAndDestroyShimStateTests {
    init() {
        SnDFixture.install()
    }

    private static let sndID = SearchAndDestroyHost.pluginID

    private let probePlugin = """
    <muclient>
    <plugin id="com.test.sndread" name="SnDRead"/>
    <aliases>
    <alias match="^probe read$" enabled="y" regexp="y" send_to="12" script="probe_read"/>
    <alias match="^probe write$" enabled="y" regexp="y" send_to="12" script="probe_write"/>
    </aliases>
    <script><![CDATA[
    local SND = "30000000537461726C696E67"
    function probe_read()
      local ok, target = CallPlugin(SND, "target_as_json")
      local ok2, targets = CallPlugin(SND, "targets_as_json")
      local ok3, count = CallPlugin(SND, "goto_list_count")
      Note("ok=" .. tostring(ok) .. " target=" .. tostring(target)
        .. " targets=" .. tostring(targets) .. " count=" .. tostring(count))
    end
    function probe_write()
      CallPlugin(SND, "do_cp_check")
    end
    ]]></script>
    </muclient>
    """

    private func noteText(_ effects: [ScriptEffect]) -> String? {
        for effect in effects {
            if case .echo(let text) = effect { return text }
            if case .note(let text, _, _) = effect { return text }
        }
        return nil
    }

    private struct StateSnapshot {
        let target: String?
        let targets: String?
        let count: String?
    }

    private func stateEffects(_ effects: [ScriptEffect]) -> [StateSnapshot] {
        effects.compactMap {
            if case .searchAndDestroyState(let target, let targets, let count) = $0 {
                return StateSnapshot(target: target, targets: targets, count: count)
            }
            return nil
        }
    }

    // MARK: - Host side: the mirror effect

    @Test("the appended accessors exist and the attach seed reads them")
    func attachSeedReadsAccessors() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // The chunk-appended accessors (file-scope locals are unreachable any
        // other way) are defined…
        #expect(await host.functionExists("targets_as_json"))
        #expect(await host.functionExists("goto_list_count"))
        // …and the unconditional seed (the attach push) carries their values:
        // no target yet, an empty target list, zero go/nx candidates.
        guard case .searchAndDestroyState(_, let targets, let count) =
            await host.shimStateEffect()
        else {
            Issue.record("expected a searchAndDestroyState effect")
            return
        }
        #expect(targets != nil)
        #expect(count == "0")
    }

    @Test("a target change emits the state effect; an unchanged run does not")
    func emitsOnChangeOnly() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        let changed = try await host.run(
            "change_target({ keyword = 'garuda', name = 'a young garuda', area = 'zoo' })"
        )
        let states = stateEffects(changed)
        #expect(states.count == 1)
        #expect(states.first?.target?.contains("garuda") == true)

        // State unchanged → no repeat effect (the diff is the whole point:
        // every GMCP message probes, only changes travel to the shim).
        let idle = try await host.run("local x = 1")
        #expect(stateEffects(idle).isEmpty)

        // Clearing the target is a change again.
        let cleared = try await host.run("clear_target()")
        #expect(stateEffects(cleared).count == 1)
        #expect(stateEffects(cleared).first?.target?.contains("garuda") != true)
    }

    // MARK: - Shim side: synchronous reads, forwarded writes

    @Test("CallPlugin reads answer synchronously from the pushed mirror")
    func shimReadsMirror() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))

        // Nothing pushed yet → reads return no value (the degrade path).
        var note = await noteText(engine.expandInput("probe read"))
        #expect(note == "ok=0 target=nil targets=nil count=nil")

        await engine.setSearchAndDestroyState(
            target: #"{"keyword":"garuda"}"#, targets: "[]", gotoCount: "9"
        )
        note = await noteText(engine.expandInput("probe read"))
        #expect(note == #"ok=0 target={"keyword":"garuda"} targets=[] count=9"#)

        // A nil field (accessor absent in the loaded S&D) reads as no value.
        await engine.setSearchAndDestroyState(target: "null", targets: nil, gotoCount: nil)
        note = await noteText(engine.expandInput("probe read"))
        #expect(note == "ok=0 target=null targets=nil count=nil")
    }

    @Test("non-read CallPlugin still forwards as a fire-and-forget effect")
    func shimWritesStillForward() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))
        await engine.setSearchAndDestroyState(target: "null", targets: nil, gotoCount: nil)
        let effects = await engine.expandInput("probe write")
        #expect(effects.contains(.callSearchAndDestroy(function: "do_cp_check", args: [])))
        // …and the reads never leak through as call effects.
        let readEffects = await engine.expandInput("probe read")
        #expect(!readEffects.contains { effect in
            if case .callSearchAndDestroy = effect { return true }
            return false
        })
    }

    // MARK: - End to end: host change → session apply → shim read

    @Test("a host-side target change becomes readable in the shim via the session")
    func endToEndThroughSession() async throws {
        let engine = try ScriptEngine()
        _ = try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: probePlugin))
        let session = SessionController(scriptEngine: engine)

        let host = try SearchAndDestroyHost()
        try await host.load()
        // The campaign was taken BEFORE the host attached (the live failure:
        // a manual `cp request`, then the plugin's campaign mode turned on).
        _ = try await host.run(
            "change_target({ keyword = 'garuda', name = 'a young garuda', area = 'zoo' })"
        )

        await session.attachSearchAndDestroy(host)

        // The attach seed makes the existing target readable immediately.
        var note = await noteText(engine.expandInput("probe read"))
        #expect(note?.contains(#""keyword":"garuda""#) == true)

        // A later change travels as a state effect through the session.
        let cleared = try await host.run("clear_target()")
        await session.applyScriptEffects(cleared)
        note = await noteText(engine.expandInput("probe read"))
        #expect(note?.contains("garuda") != true)
    }
}
