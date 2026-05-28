import Foundation
@testable import MudCore
import Testing

/// Reproduces S&D's campaign-detection scrape deterministically (no live MUD),
/// feeding the exact `cp info` line formats the reference triggers match
/// (Search_and_Destroy.xml, group `trg_campaign`).
@Suite("Search-and-Destroy — campaign detection")
struct SearchAndDestroyCampaignTests {
    init() {
        SnDFixture.install()
    }

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

    @Test("the cp_check_end pattern compiles and matches a blank line")
    func cpCheckEndPatternCompiles() throws {
        // Root-cause probe: if the end-trigger regex doesn't compile under our
        // ICU matcher, `seedEngines` silently skips it → it's never enabled →
        // `cp_check_end` never fires → no target list. It MUST compile and
        // match a blank line (its end-of-block signal) but not a target line.
        let pattern = #"^(?!You still have to kill \* .+ \(.+?(?: - Dead)?\))$"#
        let matcher = try PatternMatcher(pattern: .regex(pattern), caseSensitive: false)
        #expect(matcher.match("") != nil, "cp_check_end must match a blank line")
        #expect(
            matcher.match("You still have to kill * agony (Fantasy Fields)") == nil,
            "cp_check_end must NOT match a target line"
        )
    }

    @Test("math.random tolerates a reversed interval (the gmkw short-mob crash)")
    func mathRandomReversedInterval() async throws {
        let host = try SearchAndDestroyHost()
        try await host.load()
        // S&D's gmkw computes math.random(2 + round_banker(len*0.5), len); for a
        // 3-letter single-word mob ("a dog" → "dog") that's math.random(4, 3),
        // which standard Lua 5.1 rejects ("interval is empty"), aborting
        // build_main_target_list and losing the whole campaign. The runtime
        // clamps a reversed interval instead of throwing.
        #expect(await host.evaluate("tostring(math.random(4, 3))") != nil)
        #expect(await host.evaluate("tostring(math.random(4, 3) == 3)") == "true")
        // The 0/1-arg forms are unaffected.
        #expect(await host.evaluate("type(math.random())") == "number")
        #expect(await host.evaluate("tostring(math.random(5) >= 1 and math.random(5) <= 5)") == "true")
    }

    @Test("a full cp scrape with a 3-letter mob builds the target list (no gmkw crash)")
    func fullScrapeBuildsTargetListWithShortMob() async throws {
        // Minimal DBs in a configured world-data dir, built via the runtime's
        // own sqlite3 so the test is hermetic (no committed live DB needed).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = try SearchAndDestroyHost()
        await host.configure(directory: dir.path)
        try await host.load()
        _ = try await host.run("""
        local m = sqlite3.open(GetInfo(66) .. WorldName() .. ".db")
        m:exec[[CREATE TABLE areas (uid TEXT NOT NULL, name TEXT, texture TEXT,
          color TEXT, flags TEXT NOT NULL DEFAULT '', PRIMARY KEY(uid));
          INSERT INTO areas (uid, name) VALUES ('wow', 'War of the Wizards');]]
        m:close()
        local s = sqlite3.open(GetInfo(66) .. "/SnDdb.db")
        s:exec[[CREATE TABLE mobs (mob TEXT NOT NULL COLLATE NOCASE,
          room TEXT NOT NULL COLLATE NOCASE, roomid INTEGER NOT NULL,
          zone TEXT NOT NULL, seen_count INTEGER NOT NULL DEFAULT 0,
          kill_count INTEGER NOT NULL DEFAULT 0, UNIQUE(mob, roomid));
          CREATE TABLE mob_keyword_exceptions (area_name TEXT NOT NULL,
          mob_name TEXT NOT NULL, keyword TEXT NOT NULL,
          UNIQUE(area_name, mob_name));
          INSERT INTO mobs (mob, room, roomid, zone) VALUES ('a dog', 'A kennel', 1, 'wow');]]
        s:close()
        """)

        func feed(_ lines: [String]) async {
            for line in lines {
                _ = await host.process(line)
            }
        }
        _ = await host.scanForActivity()
        await feed([
            "Level Taken........: [ 150 ]",
            "The targets for this campaign are:",
            "Find and kill 1 * a dog (War of the Wizards)", // 3-letter mob → gmkw crash
            ""
        ])
        // do_cp_check's 1s os.clock debounce trips in a sub-second test; enable
        // the cp-check line trigger directly to drive the cp-check phase.
        _ = try await host.run(#"EnableTrigger("trg_cp_check_line", true)"#)
        await feed([
            "You still have to kill * a dog (War of the Wizards)",
            "Note: Dead means that the target is dead, not that you have killed it.",
            ""
        ])
        // Pre-fix, build_main_target_list crashed on math.random for the
        // 3-letter mob and the publish was lost; the model must now carry the
        // built target list (proof the whole chain completed).
        let model = await host.model.flatMap(SearchAndDestroyModel.decode)
        #expect(model?.playerOnCP == true, "the campaign must be detected and published")
        #expect((model?.targetCount ?? 0) > 0, "build_main_target_list must populate the target list")
        #expect(model?.targets.isEmpty == false, "the published model must carry targets")
    }

    @Test("xcp <n> on a built target routes navigation to the mapper")
    func xcpNavigatesToTarget() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = try await Self.hostWithBuiltCampaign(dir: dir)
        let model = await host.model.flatMap(SearchAndDestroyModel.decode)
        #expect((model?.targetCount ?? 0) > 0, "precondition: the target list must be built")

        // The bug under test: after the list exists, `xcp 1` must drive
        // navigation — an immediate mapper goto for a resolvable target, or (as
        // here, where the fake area has no default start room) a start-room
        // lookup + a scheduled continuation — never a silent no-op. The
        // area-target nav *continuation* is audited as the live failure suspect.
        let effects = await host.expandCommand("xcp 1")
        #expect(effects != nil, "xcp 1 must be handled by an S&D alias")
        let scheduled = await host.takeDidScheduleTimer()
        let navigated = (effects ?? []).contains { effect in
            if case .execute(let cmd) = effect { return cmd.hasPrefix("mapper") }
            if case .send(let cmd) = effect { return cmd.hasPrefix("mapper") }
            if case .sendNoEcho(let cmd) = effect { return cmd.hasPrefix("areas ") }
            return false
        }
        #expect(
            navigated || scheduled,
            "xcp 1 must drive navigation; got effects: \(effects ?? []), scheduled: \(scheduled)"
        )
    }

    /// A host whose campaign target list holds one mob (`a dog` in `War of the
    /// Wizards`, room 1), via hermetic DBs + the cp scrape. Shared by the
    /// navigation tests.
    private static func hostWithBuiltCampaign(dir: URL) async throws -> SearchAndDestroyHost {
        let host = try SearchAndDestroyHost()
        await host.configure(directory: dir.path)
        try await host.load()
        _ = try await host.run("""
        local m = sqlite3.open(GetInfo(66) .. WorldName() .. ".db")
        m:exec[[CREATE TABLE areas (uid TEXT NOT NULL, name TEXT, texture TEXT,
          color TEXT, flags TEXT NOT NULL DEFAULT '', PRIMARY KEY(uid));
          CREATE TABLE rooms (uid TEXT NOT NULL, name TEXT, area TEXT, terrain TEXT, PRIMARY KEY(uid));
          CREATE TABLE bookmarks (uid TEXT NOT NULL, notes TEXT, PRIMARY KEY(uid));
          INSERT INTO areas (uid, name) VALUES ('wow', 'War of the Wizards');
          INSERT INTO rooms (uid, name, area) VALUES ('1', 'A kennel', 'wow');]]
        m:close()
        local s = sqlite3.open(GetInfo(66) .. "/SnDdb.db")
        s:exec[[CREATE TABLE mobs (mob TEXT NOT NULL COLLATE NOCASE,
          room TEXT NOT NULL COLLATE NOCASE, roomid INTEGER NOT NULL,
          zone TEXT NOT NULL, seen_count INTEGER NOT NULL DEFAULT 0,
          kill_count INTEGER NOT NULL DEFAULT 0, UNIQUE(mob, roomid));
          CREATE TABLE mob_keyword_exceptions (area_name TEXT NOT NULL,
          mob_name TEXT NOT NULL, keyword TEXT NOT NULL, UNIQUE(area_name, mob_name));
          INSERT INTO mobs (mob, room, roomid, zone) VALUES ('a dog', 'A kennel', 1, 'wow');]]
        s:close()
        """)
        _ = await host.applyGMCP(package: "char.status", json: #"{"level":"150","state":"3"}"#)
        _ = await host.applyGMCP(package: "char.base", json: #"{"tier":"0"}"#)

        func feed(_ lines: [String]) async {
            for line in lines {
                _ = await host.process(line)
            }
        }
        _ = await host.scanForActivity()
        await feed([
            "Level Taken........: [ 150 ]",
            "The targets for this campaign are:",
            "Find and kill 1 * a dog (War of the Wizards)",
            ""
        ])
        _ = try await host.run(#"EnableTrigger("trg_cp_check_line", true)"#)
        await feed([
            "You still have to kill * a dog (War of the Wizards)",
            "Note: Dead means that the target is dead, not that you have killed it.",
            ""
        ])
        return host
    }

    @Test("qw → search_rooms populates gotoList → nx walks it to the mapper")
    func quickWherePopulatesGotoListAndNxWalksIt() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("snd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let host = try await Self.hostWithBuiltCampaign(dir: dir)

        // Stand in the target area ("wow"). A real room.info payload sets
        // current_room.arid, which qw_match's search uses as the area filter and
        // set_adhoc_target uses as the target's area. `details` must be present
        // (the room.info handler does string.match(ri.details, "maze")).
        _ = await host.applyGMCP(
            package: "room.info",
            json: #"{"num":999,"name":"@GA kennel@w","zone":"wow","details":"safe","exits":{}}"#
        )

        // `qw <mob>` arms the quick-where triggers and sends `where <mob>`.
        let qwEffects = await host.expandCommand("qw dog")
        #expect(qwEffects != nil, "qw must be handled by an S&D alias")
        #expect(
            (qwEffects ?? []).contains { effect in
                if case .send(let cmd) = effect { return cmd.lowercased().contains("where") }
                if case .sendNoEcho(let cmd) = effect { return cmd.lowercased().contains("where") }
                return false
            },
            "qw must send a `where` query; got \(qwEffects ?? [])"
        )

        // The MUD's `where` output: mob name in a 30-char field, a space, then
        // the room name (the trg_quick_where_match pattern is
        // `^(?<mobname>.{30}) (?<roomname>[^ (0-9].*)$`).
        let whereLine = "a dog".padding(toLength: 30, withPad: " ", startingAt: 0) + " A kennel"
        let matchEffects = await host.process(whereLine).effects
        // search_rooms_results renders the clickable room list; if the chain
        // breaks (trigger doesn't fire, or the mapper-DB query is empty) the
        // list never renders and gotoList stays empty.
        #expect(
            Self.effectText(matchEffects).contains { $0.contains("Location") || $0.contains("go ") },
            "the where match must render the room list; got \(matchEffects)"
        )

        // `go 1` must walk to the listed room (goto_number → goto_room_id →
        // do_mapper_goto). The user reported `go` and `nx` both dead after xcp.
        let goEffects = await host.expandCommand("go 1")
        #expect(
            (goEffects ?? []).contains { effect in
                guard case .execute(let cmd) = effect else { return false }
                return cmd == "mapper goto 1" || cmd == "mapper walkto 1"
            },
            "go 1 must drive a mapper goto/walkto for the listed room; got \(goEffects ?? [])"
        )

        // nx must now walk gotoList → a mapper goto for the found room (uid 1),
        // NOT "No more rooms" (the empty-gotoList symptom the user reported).
        let nxEffects = await host.expandCommand("nx")
        let walked = (nxEffects ?? []).contains { effect in
            if case .execute(let cmd) = effect { return cmd.contains("mapper goto 1") }
            return false
        }
        let noMore = Self.effectText(nxEffects ?? []).contains { $0.contains("No more rooms") }
        #expect(walked, "nx must drive a mapper goto for the quick-where result; got \(nxEffects ?? [])")
        #expect(!noMore, "nx must not report an empty gotoList after a successful quick-where")
    }

    /// Flattens the visible text of output effects (note/colourNote/echo) for
    /// substring assertions — S&D's InfoNote/print/ColourTell all surface here.
    private static func effectText(_ effects: [ScriptEffect]) -> [String] {
        effects.compactMap { effect in
            switch effect {
            case .note(let text, _, _): text
            case .echo(let text), .echoAard(let text), .echoAnsi(let text): text
            case .colourNote(let segments): segments.map(\.text).joined()
            default: nil
            }
        }
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
