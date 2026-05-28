import Foundation
@testable import MudCore
import Testing

@Suite("Search-and-Destroy — host dispatch (S6.2)")
struct SearchAndDestroyDispatchTests {
    init() {
        SnDFixture.install()
    }

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

    @Test("Output primitives survive an upstream global `select` clobber")
    func outputSurvivesSelectClobber() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // S&D's `search_rooms` does `select = string.format(...)` WITHOUT `local`
        // — the first quick-where/search that renders a result list clobbers
        // Lua's built-in `select` with a string. Our print/ColourTell shims call
        // select()/unpack(), so without capturing the originals this silently
        // breaks ALL subsequent S&D output (the room list, go/nx, consider).
        let effects = try await host.run("select = 'clobbered'; print('still here')")
        #expect(
            effects.contains { effect in
                if case .colourNote(let segs) = effect {
                    return segs.contains { $0.text.contains("still here") }
                }
                return false
            },
            "print must still produce output after `select` is clobbered; got \(effects)"
        )
    }

    @Test("A consider line fires the dynamic con trigger without crashing")
    func considerTriggerFiresCleanly() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // setup_scan_con_triggers registers the con_<i> dynamic triggers
        // (group "consider", script consider_trigger) via AddTriggerEx. With
        // overwrite-con ON (the default), consider_trigger iterates its 4th
        // `style` arg — which MUSHclient passes but our dynamic-trigger call
        // must too, else ipairs(nil) throws and the consider output dies.
        _ = try await host.run("""
        setup_scan_con_triggers()
        __con_ok = nil; __con_err = nil; __con_mob = nil
        local __orig = consider_trigger
        consider_trigger = function(name, line, w, style)
          local ok, err = pcall(__orig, name, line, w, style)
          __con_ok = ok; __con_err = tostring(err); __con_mob = w and w.mob_name
        end
        """)
        let result = await host.process("No Problem! a city guard is weak compared to you.")
        #expect(result.gag, "a consider outcome line must be gagged (OmitFromOutput)")
        let conErr = await host.evaluate("tostring(__con_err)") ?? "nil"
        #expect(
            await host.evaluate("tostring(__con_ok)") == "true",
            "consider_trigger must run without error; err=\(conErr)"
        )
        #expect(await host.evaluate("__con_mob") == "a city guard")
    }

    @Test("Static scan triggers run without crashing on a nil style arg")
    func scanFlowRunsCleanly() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Static S&D triggers (scan_location_current_room, scan_mob, …) take a
        // 4th MUSHclient `styles` arg; without it `ipairs(style)` throws and the
        // scan re-render is discarded (scan appears to hang). Wrap the handler
        // to prove it now runs cleanly, and that the {/scan} end still fires.
        _ = try await host.run("""
        __scan_loc_ok = nil; __scan_loc_err = nil; __scan_end_ran = false
        local __loc = scan_location_current_room
        scan_location_current_room = function(name, line, w, style)
          local ok, err = pcall(__loc, name, line, w, style)
          __scan_loc_ok = ok; __scan_loc_err = tostring(err)
        end
        local __end = scan_end
        scan_end = function(...) __scan_end_ran = true; return __end(...) end
        """)
        _ = await host.process("{scan}") // scan_start → enables the "scan" group
        let loc = await host.process("Right here you see:")
        #expect(loc.gag, "scan output lines are gagged (OmitFromOutput)")
        let err = await host.evaluate("tostring(__scan_loc_err)") ?? "nil"
        #expect(
            await host.evaluate("tostring(__scan_loc_ok)") == "true",
            "scan_location_current_room must run without error; err=\(err)"
        )
        _ = await host.process("{/scan}") // scan_end
        #expect(await host.evaluate("tostring(__scan_end_ran)") == "true", "the {/scan} end must fire")
    }

    @Test("A matched line's colour runs reach the trigger's `styles` arg")
    func styledRunsReachTriggerStyles() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // A trigger that re-renders the matched line from its 4th `styles` arg,
        // exactly like S&D's scan/consider handlers (RGBColourToName(textcolour)).
        _ = try await host.run("""
        function on_styled(name, line, w, style)
          for i, s in ipairs(style) do
            ColourTell(RGBColourToName(s.textcolour), "", s.text)
          end
          print("")
        end
        AddTriggerEx("t_styled", "^a green mob$", "",
                     trigger_flag.Enabled + trigger_flag.RegularExpression,
                     -1, 0, "", "on_styled", sendto.script, 100)
        """)
        // Feed the line with a bright-green foreground run over the whole text.
        let text = "a green mob"
        let green = StyleAttributes(foreground: .brightNamed(.green))
        let runs = [StyledRun(utf16Range: 0..<text.utf16.count, style: green)]
        let effects = await host.process(text, runs: runs).effects
        // xtermDefault bright green = RGB(0,255,0) → BGR int → "#00ff00".
        #expect(
            effects.contains { effect in
                guard case .colourNote(let segs) = effect else { return false }
                return segs.contains { $0.text == "a green mob" && $0.foreground == "#00ff00" }
            },
            "the trigger must receive the line's colour runs in `styles`; got \(effects)"
        )
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

    @Test("xrt <area> resolves via areaDefaultStartRooms and routes the mapper")
    func xrtRoutesThroughMapper() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Feed char data so tier_level() (used by the vidblain check on the
        // goto path) has level/tier — present live, absent in a bare test.
        _ = await host.applyGMCP(package: "char.status", json: #"{"level":"150"}"#)
        _ = await host.applyGMCP(package: "char.base", json: #"{"tier":"0"}"#)
        // xrt adaldar → get_start_room → areaDefaultStartRooms["adaldar"].start
        // (34400) → do_mapper_goto → Execute("mapper goto 34400"). The .execute
        // re-enters the command pipeline → the native mapper walks there.
        #expect(await host.evaluate("get_start_room('adaldar', false)") == "34400")
        let effects = await host.expandCommand("xrt adaldar")
        #expect(effects != nil)
        #expect(effects?.contains { effect in
            if case .execute(let cmd) = effect { return cmd == "mapper goto 34400" }
            return false
        } == true)
    }

    @Test("EnableTriggerGroup drives the group enable (CP/GQ state machine)")
    func enableTriggerGroupBound() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // S&D toggles its campaign/GQ trigger groups via EnableTriggerGroup,
        // not EnableGroup — it must route to the same enableGroup effect.
        #expect(await host.functionExists("EnableTriggerGroup"))
        let effects = try await host.run("EnableTriggerGroup('trg_campaign', true)")
        #expect(effects.contains(.enableGroup(name: "trg_campaign", on: true)))
    }

    @Test("Previously-missing world globals are defined (can't abort a firing)")
    func missingGlobalsStubbed() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        for name in [
            "EnableTriggerGroup", "EnableTimerGroup", "EnableAlias", "AddTriggerEx",
            "SetTriggerOption", "GetTriggerList", "GetTriggerInfo", "GetVariableList",
            "GetPluginVariable", "SetClipboard"
        ] {
            #expect(await host.functionExists(name), "\(name) should be defined")
        }
    }

    @Test("AddTriggerEx registers a live trigger that fires + obeys its group")
    func dynamicTriggerFires() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Register a runtime trigger (group "scan") like S&D's scan/consider setup.
        _ = try await host.run("""
        testfired = false
        function on_test(name, line, w) testfired = true end
        AddTriggerEx("t_test", "^ping$", "", trigger_flag.Enabled + trigger_flag.RegularExpression,
                     -1, 0, "", "on_test", sendto.script, 100)
        SetTriggerOption("t_test", "group", "scan")
        """)
        // A matching line fires the handler.
        _ = await host.process("ping")
        #expect(await host.evaluate("tostring(testfired)") == "true")
        // Disabling its group stops it firing (EnableTriggerGroup drives the engine).
        _ = try await host.run("EnableTriggerGroup('scan', false); testfired = false")
        _ = await host.process("ping")
        #expect(await host.evaluate("tostring(testfired)") == "false")
    }

    @Test("EnableAlias records a host-internal enable effect")
    func enableAliasRecorded() async throws {
        let runtime = try LuaRuntime()
        let effects = try await runtime.run("proteles.enableAlias('a_test', true)")
        #expect(effects.contains(.enableAlias(name: "a_test", on: true)))
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

    @Test("GMCP room.info updates current_room so execute_in_area detects arrival")
    func roomInfoUpdatesCurrentRoom() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Project a real Aardwolf room.info payload (from a live capture) and
        // fire S&D's OnPluginBroadcast, which sets current_room.arid =
        // gmcp("room.info").zone. The `details` field matters: the handler does
        // string.match(ri.details, "maze"), so a payload missing it aborts.
        _ = await host.applyGMCP(
            package: "room.info",
            json: #"""
            { "num": 2339, "name": "@GA Light Provisions Room@w", "zone": "light",
              "terrain": "inside", "details": "safe,shop,healer,questor",
              "exits": { "n": 2343, "e": 2341 } }
            """#
        )
        // execute_in_area runs its func immediately when already in the target
        // area (current_room.arid == arid). If room.info didn't reach
        // current_room, this never fires — which is the prime "dies after xcp 1"
        // suspect (the arrival poll never completes its on-arrival action).
        _ = try await host.run(
            "snd_arrived = false; execute_in_area('light', function() snd_arrived = true end)"
        )
        #expect(
            await host.evaluate("tostring(snd_arrived)") == "true",
            "room.info must update current_room.arid so the on-arrival action fires"
        )
    }

    @Test("execute_in_area's poll timer runs the on-arrival action once the room updates")
    func executeInAreaPollFiresOnArrival() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // Start in a different area → execute_in_area enables the 0.1s poll timer
        // (the real flow: the player is walking there via mapper goto).
        _ = await host.applyGMCP(package: "char.status", json: #"{"state":"3"}"#)
        _ = await host.applyGMCP(
            package: "room.info",
            json: #"{"num":1,"zone":"other","details":"","exits":{}}"#
        )
        _ = try await host.run(
            "snd_arrived = false; execute_in_area('light', function() snd_arrived = true end)"
        )
        #expect(await host.evaluate("tostring(snd_arrived)") == "false", "not yet in area → deferred")

        // Arrive: room.info zone becomes the target. The poll must now detect it.
        _ = await host.applyGMCP(
            package: "room.info",
            json: #"{"num":2339,"zone":"light","details":"safe","exits":{}}"#
        )
        let base = Date()
        for index in 0..<8 {
            _ = await host.fireTimers(at: base.addingTimeInterval(0.2 * Double(index)))
        }
        #expect(
            await host.evaluate("tostring(snd_arrived)") == "true",
            "the execute_in_area poll timer must detect arrival and run the on-arrival action"
        )
    }

    @Test("process() runs incoming lines through S&D's triggers without crashing")
    func processLineIsSafe() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // An empty line matches nothing → no effects; arbitrary game lines must
        // also stay well-behaved (no throw / crash).
        #expect(await host.process("").effects.isEmpty)
        _ = await host.process("You receive 5 experience points.")
    }
}
