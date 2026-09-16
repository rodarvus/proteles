import Foundation
@testable import MudCore
import Testing

/// Offline wishlist replay through SessionController, its timer loop and inbound
/// gag pipeline. The simulated server echoes only commands the plugin sends.
/// Recognizable report lines are hidden; unrelated lines remain visible. A
/// missing header must not publish incomplete wishes or overwrite saved wishes.
@Suite("dinv — wish-list gag (real session)", .serialized)
struct DinvWishGagTests {
    /// Recorded wish-list report (2026-06-01), also observed in September.
    private static let header =
        "                                    Base Cost Adjustment Your Cost  Keyword"
    /// The real `wish list` output (live capture, 2026-06-01). No pre-header line;
    /// owned wishes are the `*`-prefixed rows.
    private static let body: [String] = [
        header,
        " ---------------------------------- --------- ---------- --------- -----------",
        "*Very fast spell-up time                 6000        250        -- Spellup    ",
        " No hunger or thirst                     3000          0      3000 Nohunger  ",
        " Immunity to Vorpal                      5000        300      8000 Novorpal  ",
        " Immunity to Dirt Kick                   3000        200      6000 Nodirt    ",
        " Immunity to Marbu Poison                4000        200      7000 Nomarbu    ",
        " Immunity to Web (non PvP)               6000        200      9000 Noweb      ",
        " Weaponsmaster                           4000        150      7000 Weapons    ",
        " Night Vision                            4000        150      7000 Nightvision",
        " Showscry                                1500        100      4500 Showscry  ",
        " A free rebuild                           500          0       500 Rebuild    ",
        "*Permanent Passdoor                      5000        250        -- Passdoor  ",
        "*Reduction in a stat cost               10000        350        -- Statcost  ",
        "*10% more exp on kills                   6000        200        -- Exprate    ",
        "*Spellup duration 50% higher             5000        200        -- Duration  ",
        "*Carry +100 items                        3500        200        -- Pockets    ",
        " People can't see your worn eq           6000        250      9000 Privacy    ",
        " Can uncurse all items at once           7000        500     10000 Uncurse    ",
        "*Portal wear location                    6000        150        -- Portal    ",
        " Mobs cannot teleport you                6000        200      9000 Noteleport",
        "*Faster recovery from hunting            5000        300        -- Fasthunt  ",
        " Cannot be spooked by mobs               6000        300      9000 Bravery    ",
        " Perm underwater breathing               4000        300      7000 Gills      ",
        " Carry +100 items                        6500        250      9500 Pockets2  ",
        "*Access to full 'identify'               2500        200        -- Identify  ",
        " Additional 40 friend slots              6000        200      9000 Popularity",
        "*Failed spell time reduction             6000        200        -- Spellup2  ",
        "*Practice to 95% instead of 85%          8000        200        -- Scholar    ",
        " Auctioneer                              5000          0      5000 Auctioneer",
        "*Add +1 bypass (all classes)             6000        250        -- Bypass    ",
        "*Add +1 bypass (all classes)            10000        250        -- Bypass2    ",
        "Your total adjustment cost is: 3000",
        "Your quest points on hand are: 1540",
        "Refer to 'help wish' for a description of each wish."
    ]

    private func registerAppPlugins(on engine: ScriptEngine, dir: URL) async {
        await engine.registerNativePlugin(AardGMCPHandler())
        await engine.registerNativePlugin(VitalShortcuts())
        await engine.registerNativePlugin(NoteMode())
        await engine.registerNativePlugin(TextSubstitution())
        await engine.registerNativePlugin(ChatEcho())
        await engine.registerNativePlugin(AsciiMap())
        await engine.registerNativePlugin(TickTimer())
        await engine.registerNativePlugin(URLLinkify())
        await engine.registerModules(DinvAssets.modules)
        await engine.setSQLiteDirectory(dir.path)
    }

    /// Boot dinv in a live session, go in-game, drive the real timer loop ~18s
    /// while playing the MUD: answer each fence echo + dinv's `pagesize`/`wish
    /// list` probes. dinv's post-init 1s timer fires `dbot.wish.get` on its own.
    /// `wishLines` is the exact `wish list` body the fake MUD replays.
    /// Returns the lines that were SHOWN (not gagged) of that block.
    private func runWishFlow(
        wishLines: [String],
        competing: [Trigger] = []
    ) async throws -> (leaked: [String], wishHasPortal: Bool) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dinv-wishsess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = try ScriptEngine()
        await registerAppPlugins(on: engine, dir: dir)
        let conn = InMemoryConnection()
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn })
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        await controller.dispatchGMCP(GMCPMessage(
            package: "char.status", json: #"{"level":150,"state":3,"pos":"Standing"}"#
        ))
        await controller.armBundledDinv(stateDirectory: dir.path)
        await controller.loadPendingDinv()
        await controller.dispatchGMCP(GMCPMessage(
            package: "char.base", json: #"{"name":"Tester","class":"Mage"}"#
        ))
        // Inject any competing triggers (e.g. the real Aardwolf_Rsocial_Capture
        // `^\*.+$` stop-on-match trigger) into the SAME shared engine dinv's wish
        // trigger lives in — so the sequence ordering is exercised live.
        for trigger in competing {
            try? await engine.addTrigger(trigger)
        }

        await driveDinvWishExchange(controller: controller, engine: engine, conn: conn, wishLines: wishLines)

        let sent = conn.sentLines
        #expect(sent.contains("wish list"), "VACUOUS: dinv never sent `wish list`: \(sent)")
        let shown = await controller.scrollbackStore.snapshot().map(\.text)
        // Non-vacuity: the post-fence sentinel proves the wish output reached the
        // inbound pipeline (so an empty `leaked` means genuinely gagged, not
        // never-delivered).
        #expect(
            shown.contains("PROTELES_SENTINEL_AFTER_FENCE"),
            "VACUOUS: wish output never reached the pipeline (no sentinel): \(shown)"
        )
        // Probe the actual portal-slot determinant: did dinv parse the owned
        // "Portal" wish? `inv.portal.use` branches on `dbot.wish.has("Portal")`;
        // it's true only if dinv's wish trigger fired on the owned `*Portal` row.
        let wishHasPortal = await Self.dinvHasWish("Portal", on: engine)

        await controller.disconnect()
        // Scrollback text is ANSI-stripped, so compare against stripped wish lines.
        let strippedWishes = Set(wishLines.map(Self.stripANSI))
        let leaked = shown.filter { strippedWishes.contains($0) }
        return (leaked: leaked, wishHasPortal: wishHasPortal)
    }

    /// Drive the real timer loop ~18s, answering dinv's `pagesize`/`wish list`
    /// probes + fence echoes as the fake MUD would (split out of ``runWishFlow``
    /// to keep it within the function-length budget).
    /// Reply to a command dinv sent, the way the fake MUD would: echo its
    /// coordinator fences, replay the `wish list` body + a non-vacuity
    /// sentinel, and answer the `pagesize` probes. A command can be glued to a
    /// preceding GMCP subnegotiation in one flush, so match the *trailing* command.
    private static func answerProbe(_ line: String, conn: InMemoryConnection, wishLines: [String]) {
        if let range = line.range(of: "echo { DINV fence") {
            conn.injectLine(String(line[range.lowerBound...].dropFirst("echo ".count)))
        } else if line.hasSuffix("wish list") {
            wishLines.forEach { conn.injectLine($0) }
            conn.injectLine("PROTELES_SENTINEL_AFTER_FENCE")
        } else if line.hasSuffix("pagesize 0") {
            conn.injectLine("Paging disabled.")
        } else if line.hasSuffix("pagesize 20") {
            conn.injectLine("Page size set to 20 lines.")
        } else if line.hasSuffix("pagesize") {
            conn.injectLine("You currently display 20 lines per page.")
        }
    }

    /// Whether the post-fence sentinel has reached scrollback — i.e. the wish
    /// flow finished, so the drive loop can stop early.
    private static func flowCompleted(_ controller: SessionController, engine: ScriptEngine) async -> Bool {
        guard await controller.scrollbackStore.snapshot()
            .contains(where: { $0.text.contains("PROTELES_SENTINEL_AFTER_FENCE") }) else { return false }
        let effects = await engine.runInPluginEnvironment(
            DinvAssets.pluginID,
            "if not dbot.wish.inProgress then proteles.note('WISH_FINISHED') end"
        )
        return effects.contains { if case .note("WISH_FINISHED", _, _) = $0 { true } else { false } }
    }

    private func driveDinvWishExchange(
        controller: SessionController,
        engine: ScriptEngine,
        conn: InMemoryConnection,
        wishLines: [String]
    ) async {
        var answered = Set<String>()
        // A generous safety cap, not a fixed run-time: we exit as soon as the
        // wish flow has completed (the post-fence sentinel reaches scrollback).
        // A fixed window flaked on CI, where parallel-test contention delays
        // dinv's timer-driven init past the deadline before the wish step runs.
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var tick = 0
        while ContinuousClock.now < deadline {
            tick += 1
            // Done the moment the flow completes — fast locally, patient on CI.
            if await Self.flowCompleted(controller, engine: engine) { break }
            if tick % 25 == 0 {
                await controller.dispatchGMCP(GMCPMessage(
                    package: "char.status", json: #"{"level":150,"state":3,"pos":"Standing"}"#
                ))
            }
            for line in conn.sentLines where answered.insert(line).inserted {
                Self.answerProbe(line, conn: conn, wishLines: wishLines)
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Ask dinv (in its own plugin env) whether it has parsed a given wish.
    private static func dinvHasWish(_ name: String, on engine: ScriptEngine) async -> Bool {
        for case .note(let text, _, _) in await engine.runInPluginEnvironment(
            DinvAssets.pluginID,
            "proteles.note('DINVWISH=' .. tostring("
                + "dbot and dbot.wish and dbot.wish.has and dbot.wish.has('\(name)')))"
        ) where text.contains("DINVWISH=") {
            return text.contains("DINVWISH=true")
        }
        return false
    }

    /// Strip ANSI SGR escape sequences (`ESC [ … m`) from a string — the pipeline
    /// does this when building `Line.text`, so a leaked line in the scrollback is
    /// the stripped form.
    private static func stripANSI(_ string: String) -> String {
        var out = ""
        var inEscape = false
        for scalar in string.unicodeScalars {
            if inEscape {
                if scalar == "m" { inEscape = false }
            } else if scalar == "\u{1b}" {
                inEscape = true
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    @Test(
        "dinv gags the real wish-list body (header → fence) through the real session",
        .timeLimit(.minutes(1))
    )
    func wishBodyGagged() async throws {
        let leaked = try await runWishFlow(wishLines: Self.body).leaked
        #expect(leaked.isEmpty, "wish-list body leaked to the user: \(leaked)")
    }

    @Test("Unrelated output inside a wishlist remains visible in the real session", .timeLimit(.minutes(1)))
    func unrelatedOutputDuringWish() async throws {
        var interleaved = Self.body
        let chat = "A friend tells you 'hello during the wishlist'."
        interleaved.insert(chat, at: 4)
        let result = try await runWishFlow(wishLines: interleaved)
        #expect(result.leaked == [chat])
        #expect(result.wishHasPortal)
    }

    /// The REAL output is ANSI-coloured: owned (`*`) rows begin with a bold-red
    /// star (`ESC[0;1;31m*ESC[0;36m…`), non-owned rows don't. The live leak shows
    /// only the owned rows, so reproduce with the actual colour codes (a plain-text
    /// harness can't catch a colour-dependent gag failure).
    private static let esc = "\u{1b}"
    private static func ownedRow(_ name: String, _ keyword: String) -> String {
        "\(esc)[0;1;31m*\(esc)[0;36m\(name)\(esc)[0;37m   6000   250   -- \(keyword)    \(esc)[0m"
    }

    private static func unownedRow(_ name: String, _ keyword: String) -> String {
        "\(esc)[0;37m \(name)   3000   200   7000 \(keyword)    \(esc)[0m"
    }

    /// Wrap plain text in normal-white SGR (`ESC[0;37m … ESC[0m`).
    private static func white(_ text: String) -> String {
        "\(esc)[0;37m\(text)\(esc)[0m"
    }

    private static var colouredBody: [String] {
        [
            white("                                    Base Cost Adjustment Your Cost  Keyword"),
            white(" ---------------------------------- --------- ---------- --------- -----------"),
            ownedRow("Very fast spell-up time          ", "Spellup"),
            unownedRow("No hunger or thirst             ", "Nohunger"),
            ownedRow("Permanent Passdoor               ", "Passdoor"),
            unownedRow("Immunity to Vorpal              ", "Novorpal"),
            ownedRow("Add +1 bypass (all classes)      ", "Bypass"),
            white("Your total adjustment cost is: 3000"),
            white("Refer to 'help wish' for a description of each wish.")
        ]
    }

    @Test(
        "dinv gags the wish-list even when rows are ANSI-coloured (real output)",
        .timeLimit(.minutes(1))
    )
    func wishBodyGaggedWithColour() async throws {
        let leaked = try await runWishFlow(wishLines: Self.colouredBody).leaked
        #expect(leaked.isEmpty, "coloured wish rows leaked to the user: \(leaked)")
    }

    @Test(
        "Missing wish header retains saved state and leaves unrelated text visible",
        .timeLimit(.minutes(1))
    )
    func wishBodyGaggedWhenHeaderUnmatched() async throws {
        var mangled = Self.body
        mangled[0] = "  <<< an unrelated banner >>>"
        let result = try await runWishFlow(wishLines: mangled)
        #expect(result.leaked == [mangled[0]], "Recognizable wish rows must remain hidden")
        #expect(!result.wishHasPortal, "Missing header must not publish a partial report")
    }

    /// END-TO-END proof for D-84 (portal-when-worn / Finding 1). The live failure:
    /// dinv never parsed the owned `*Portal` wish row, so `dbot.wish.has("Portal")`
    /// was false and `inv.portal.use` targeted the hold slot (the Lasso) instead of
    /// the worn portal slot. Root cause was a co-loaded plugin's stop-on-match
    /// trigger pre-empting dinv's wish trigger on the `*` rows — the real culprit is
    /// Aardwolf_Rsocial_Capture's `^\*.+$` (sequence 10, `keep_evaluating` absent →
    /// stop). dinv registers its wish trigger via `AddTriggerEx(…, 0)` (sequence 0)
    /// so it should win, but our runtime AddTriggerEx dropped the sequence (→ 100)
    /// and lost. This drives the REAL dinv wish flow with the actual Rsocial trigger
    /// present in the shared engine and asserts dinv still parses "Portal". With
    /// D-84 it passes; reverting the sequence threading makes it fail (Portal lost).
    @Test("dinv parses the owned Portal wish past a stop-on-match preemptor (D-84)", .timeLimit(.minutes(1)))
    func ownedPortalWishParsedDespiteStopOnMatchPreemptor() async throws {
        // The real Aardwolf_Rsocial_Capture trigger: matches any `*`-prefixed line,
        // regex, NOT omit-from-output, sequence 10, keep_evaluating absent → STOP.
        let rsocial = Trigger(
            pattern: .regex("^\\*.+$"),
            sequence: 10,
            continueEvaluation: false
        )
        let result = try await runWishFlow(wishLines: Self.body, competing: [rsocial])
        #expect(
            result.wishHasPortal,
            "dinv failed to parse the owned 'Portal' wish — a stop-on-match trigger pre-empted it"
        )
    }
}
