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
            published += await host.process(line)
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
