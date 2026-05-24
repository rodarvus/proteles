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

    @Test("scanForActivity drives S&D's do_cp_info (sends 'cp info')")
    func scanForActivityRunsCpInfo() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        let effects = await host.scanForActivity()
        // do_cp_info enables its scrape triggers and SendNoEcho("cp info");
        // the cp-info end line then sets current_activity = "cp" + publishes.
        #expect(effects.contains { effect in
            if case .sendNoEcho(let cmd) = effect { return cmd.contains("cp info") }
            if case .send(let cmd) = effect { return cmd.contains("cp info") }
            return false
        })
    }

    @Test("Network self-update is stubbed (no download_file side effects)")
    func downloadStubbed() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // download_file is overridden to a no-op, so calling it (and the
        // update entry points) produces no effects / no error note.
        let effects = try await host.run(
            "download_file('https://example.com/x', function() end); check_for_updates()"
        )
        #expect(!effects.contains { effect in
            if case .note(let text, _, _) = effect { return text.contains("download") }
            return false
        })
    }

    @Test("MUSHclient colour built-ins S&D calls are bound (no nil-call error)")
    func colourBuiltinsBound() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        #expect(await host.functionExists("ColourNameToRGB"))
        #expect(await host.functionExists("RGBColourToName"))
        #expect(await host.functionExists("GetNormalColour"))
        // Round-trips a #RRGGBB colour through the (BGR) int form.
        #expect(await host.evaluate("RGBColourToName(ColourNameToRGB(\"#102030\"))") == "#102030")
    }

    @Test("GMCP feeds S&D's runtime and its gmcp() accessor reads it back")
    func gmcpProjection() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Project char.status into S&D's runtime (the path it uses to learn
        // its state) and fire its OnPluginBroadcast.
        _ = await host.applyGMCP(package: "char.status", json: #"{"state":"3","level":"150"}"#)
        // S&D's gmcp("char.status.<field>") → CallPlugin → our handler shim
        // reading proteles.gmcp.
        #expect(await host.evaluate(#"gmcp("char.status.state")"#) == "3")
        #expect(await host.evaluate(#"gmcp("char.status.level")"#) == "150")
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
