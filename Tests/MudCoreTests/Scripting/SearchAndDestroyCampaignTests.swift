import Foundation
@testable import MudCore
import Testing

/// Reproduces S&D's campaign-detection scrape deterministically (no live MUD),
/// feeding the exact `cp info` line formats the reference triggers match
/// (Search_and_Destroy.xml, group `trg_campaign`).
@Suite("Search-and-Destroy — campaign detection")
struct SearchAndDestroyCampaignTests {
    /// The reference `cp info` output (area campaign), per the trigger patterns:
    /// - `^Level Taken\.{8}: \[\s+(?<level>…) \]$`
    /// - `^The targets for this campaign are:$`
    /// - `^Find and kill 1 \* (?<target>.+)$`
    /// - end: a non-target line (`^(?!Find and kill 1 \* .+ \(.+\))$`, i.e. blank)
    private static let cpInfoOutput = [
        "Level Taken........: [ 150 ]",
        "The targets for this campaign are:",
        "Find and kill 1 * a city guard (Aylorian Academy)",
        "Find and kill 1 * the gatekeeper (Aylorian Academy)",
        "" // trailing blank line → cp_info_end
    ]

    @Test("A cp info scrape sets activity = cp and publishes a model")
    func cpInfoScrapeDetectsCampaign() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()

        // do_cp_info enables the scrape triggers + sends "cp info".
        _ = await host.scanForActivity()
        // Feed the MUD's cp info response, line by line, as the session would.
        var published: [ScriptEffect] = []
        for line in Self.cpInfoOutput {
            published += await host.process(line).effects
        }

        // cp_info_end (fired by the trailing blank line) sets current_activity
        // and publishes — the publish must survive (previously a nil `sendto`
        // in DoAfterSpecial threw and discarded it).
        let hadPublish = published.contains { if case .publishModel = $0 { return true }; return false }
        #expect(hadPublish, "the cp_info_end scrape should publish a model")

        let model = await (host.model).flatMap(SearchAndDestroyModel.decode)
        #expect(model?.activity == "cp", "published model activity should be 'cp'")
        #expect(model?.playerOnCP == true)
    }

    @Test("auto-detects an in-progress campaign on connect (no manual cp)")
    func autoDetectsCampaignOnConnect() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        await host.setConnected(true)
        // Ready state so init_plugin's gate (current_character_state in 3/8/9/11)
        // passes; otherwise it just re-requests char and never completes init.
        _ = await host.applyGMCP(
            package: "char.status",
            json: #"{"level":4,"state":3,"pos":"Standing"}"#
        )
        // tim_init_plugin (0.5s) runs twice → init completes → the
        // setup_scan_con_triggers hook arms trg_cp_info_targets persistently.
        for i in 1...4 {
            _ = await host.fireTimers(at: Date().addingTimeInterval(Double(i) * 0.6))
        }
        // Aardwolf auto-shows the campaign on login, BEFORE any requested
        // `cp info`. Feed that auto-shown block with no manual `cp` typed: the
        // pre-armed entry trigger must parse it and detect the campaign.
        // (Before the fix the entry trigger wasn't armed in time, so the block
        // scrolled by unparsed and the campaign went undetected.)
        for line in [
            "--------------------------[ YOUR CURRENT CAMPAIGN ]----------------------",
            "Level Taken........: [     8 ]",
            "----------------------------[ Campaign Victims ]-------------------------",
            "The targets for this campaign are:",
            "Find and kill 1 * a pink fairy armadillo (Aardwolf Zoological Park)",
            "Find and kill 1 * a stool (War of the Wizards)",
            "--------------------------------------------------------------------------",
            "Use 'cp check' to see only targets that you still need to kill.",
            ""
        ] {
            _ = await host.process(line)
        }
        let model = await host.model.flatMap(SearchAndDestroyModel.decode)
        #expect(model?.playerOnCP == true, "an auto-shown campaign must be detected on connect")
        #expect(model?.activity == "cp")
    }

    @Test("a new campaign after completing one is still detected (group re-enable)")
    func newCampaignAfterCompletionDetected() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        await host.setConnected(true)
        _ = await host.applyGMCP(
            package: "char.status",
            json: #"{"level":8,"state":3,"pos":"Standing"}"#
        )
        for i in 1...4 {
            _ = await host.fireTimers(at: Date().addingTimeInterval(Double(i) * 0.6))
        }

        func feedCampaign() async {
            for line in [
                "The targets for this campaign are:",
                "Find and kill 1 * a pink fairy armadillo (Aardwolf Zoological Park)",
                ""
            ] {
                _ = await host.process(line)
            }
        }
        func onCP() async -> Bool {
            await host.model.flatMap(SearchAndDestroyModel.decode)?.playerOnCP == true
        }

        await feedCampaign()
        #expect(await onCP(), "first campaign should be detected")

        // Complete it → do_cp_complete → player_not_on_cp → disables trg_campaign.
        _ = await host.process("CONGRATULATIONS! You have completed your campaign.")
        #expect(await !onCP(), "completing clears the campaign")

        // Request a NEW campaign: do_cp_info re-enables trg_cp_info_targets. In
        // MUSHclient an individual enable overrides a group disable; our group
        // gate used to keep it dead, so the new campaign went undetected.
        _ = await host.scanForActivity()
        await feedCampaign()
        #expect(await onCP(), "a new campaign after completing one must be detected")
    }

    @Test("gmcp() stringifies scalar leaves so is_character_ready works")
    func gmcpScalarIsString() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Aardwolf sends char.status.state as a JSON *number*; S&D compares it
        // to the string "3" (is_character_ready). Without stringifying, xcp/go/
        // nx wrongly print "You can't run there while you're ready!".
        _ = await host.applyGMCP(
            package: "char.status",
            json: #"{"level":201,"state":3,"pos":"Standing","enemy":""}"#
        )
        #expect(await host.evaluate(#"gmcp("char.status.state")"#) == "3")
        #expect(await host.evaluate(#"type(gmcp("char.status.state"))"#) == "string")
        // The navigation guard now passes for a ready character.
        #expect(await host.evaluate("tostring(is_character_ready())") == "true")
        // A numeric field is still usable as a number.
        #expect(await host.evaluate(#"tostring(tonumber(gmcp("char.status.level")))"#) == "201")
    }

    @Test("os.clock is sub-second wall time (so the cp-check debounce doesn't misfire)")
    func osClockIsWallTime() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // macOS Lua's os.clock is CPU time (~0 in an idle test); the override
        // makes it wall seconds, so S&D's `last_cp_check` 1s debounce behaves.
        let clock = await host.evaluate("tostring(os.clock())")
        let value = Double(clock ?? "0") ?? 0
        #expect(value > 1_000_000_000, "os.clock should be wall-clock epoch seconds, got \(clock ?? "nil")")
        // Crucially it must be SUB-SECOND, not integer `os.time()` seconds.
        // Integer resolution let a stray `do_cp_check` ~0.3s later read a full
        // second on and escape the 1s debounce, resetting `cp_check_list`
        // mid-scrape → "No target items". Sampling many times, at least one
        // reading must carry a fractional part (impossible with integer seconds).
        let probe = """
        (function()
          for i = 1, 200000 do
            local c = os.clock()
            if c ~= math.floor(c) then return "1" end
          end
          return "0"
        end)()
        """
        let fractional = await host.evaluate(probe)
        #expect(fractional == "1", "os.clock must have sub-second resolution, got integer seconds")
    }

    @Test("cp check scrape output is gagged from the window (omit_from_output)")
    func cpCheckLinesAreGagged() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // `trg_cp_check_gag_dead` is enabled by default with omit_from_output —
        // a real recorded trailer line must be gagged from the window. This
        // proves S&D's gag now reaches the session (process returns gag=true).
        let trailer = await host.process(
            "Note: Dead means that the target is dead, not that you have killed it."
        )
        #expect(trailer.gag, "the cp-check trailer must be gagged")
        // An ordinary game line is never gagged.
        let normal = await host.process("A goblin hits you.")
        #expect(!normal.gag)
    }

    @Test("cp_info_end no longer throws (sendto is defined; DoAfterSpecial works)")
    func cpInfoEndDoesNotThrow() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // sendto must be a table so DoAfterSpecial(..., sendto.script) resolves.
        #expect(await host.evaluate("type(sendto)") == "table")
        #expect(await host.evaluate("tostring(sendto.script)") == "12")
        // DoAfterSpecial schedules a one-shot rather than erroring/no-op'ing.
        let effects = try await host.run("DoAfterSpecial(0.1, [[ x = 1 ]], sendto.script)")
        #expect(effects.contains { if case .scheduleAfter = $0 { return true }; return false })
    }
}
