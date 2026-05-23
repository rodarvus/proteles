import Foundation
@testable import MudCore
import Testing

@Suite("Search-and-Destroy — host dispatch (S6.2)")
struct SearchAndDestroyDispatchTests {
    @Test("Named captures land on the `matches` table (wildcards.<name>)")
    func namedCapturesOnMatchesTable() async throws {
        let runtime = try LuaRuntime()
        _ = try await runtime.runScript(
            "captured = matches.mob",
            matches: ["a guard hits you", "a guard"],
            named: ["mob": "a guard"]
        )
        // MUSHclient passes a single wildcards table carrying both numbered
        // and named keys — S&D reads wildcards.mob_name off it directly.
        #expect(try await runtime.string("captured") == "a guard")
        #expect(try await runtime.string("matches[0]") == "a guard hits you")
    }

    @Test("proteles.enableTrigger/Timer/Group record host-internal effects")
    func enableEffectsRecorded() async throws {
        let runtime = try LuaRuntime()
        let effects = try await runtime.run("""
        proteles.enableTrigger("trg_a", true)
        proteles.enableTimer("tim_b", false)
        proteles.enableGroup("grp_c", true)
        """)
        #expect(effects.contains(.enableTrigger(name: "trg_a", on: true)))
        #expect(effects.contains(.enableTimer(name: "tim_b", on: false)))
        #expect(effects.contains(.enableGroup(name: "grp_c", on: true)))
    }

    @Test("Underscored named groups compile and extract (ICU-incompatible PCRE)")
    func underscoredNamedGroups() {
        // S&D's damage trigger names its capture (?<mob_name>…); ICU rejects
        // the underscore unless we sanitise it.
        let matcher = try? PatternMatcher(
            pattern: .regex(#"^You kill (?<mob_name>.+)\.$"#),
            caseSensitive: false
        )
        let match = matcher?.match("You kill a city guard.")
        #expect(match?.named["mob_name"] == "a city guard")
    }

    @Test("Aliases match S&D commands and pass non-commands through")
    func aliasMatching() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()

        // A line that isn't an S&D command → no firing → the caller sends it.
        let passthrough = await host.expandCommand("look at the fountain zzz")
        #expect(passthrough == nil)

        // "xcp" is one of S&D's aliases → it matches (effects array, possibly
        // empty if its handler errors — but non-nil means "handled"). "snd
        // history" exercises an underscored named-group alias too.
        #expect(await host.expandCommand("xcp") != nil)
        #expect(await host.expandCommand("snd history") != nil)
    }

    @Test("process() runs incoming lines through S&D's triggers without crashing")
    func processLineIsSafe() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // An empty line matches nothing → no effects; arbitrary game lines must
        // also stay well-behaved (no throw / crash).
        #expect(await host.process("").isEmpty)
        _ = await host.process("You receive 5 experience points.")
    }
}
