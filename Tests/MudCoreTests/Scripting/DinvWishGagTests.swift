import Foundation
@testable import MudCore
import Testing

/// Faithful, offline reproduction of dinv's `wish list` gag — driven through the
/// **real** ``SessionController`` (its `OnPluginSend` bypass re-entrancy guard +
/// async timer loop + inbound gag pipeline) over an ``InMemoryConnection``, NOT
/// the bespoke ``ScriptEngine`` driver (which lacks the re-entrancy guard) and
/// NOT a hand-call of `dbot.wish.setupFn` (which sidesteps the queue/fence
/// coroutine `DinvBuildHarnessTests.wishListOutputIsGagged` so it can't catch a
/// timing leak).
///
/// What this pins down (D-77): driving the real `dbot.wish.get` → `getCR`
/// coroutine end to end — answering the `pagesize` probe, echoing both safe-exec
/// fences and the wish fence, replaying the user's real `wish list` body — dinv's
/// gag, *with intact triggers*, correctly omits the column header, every item
/// row, the totals, and the fence (proven non-vacuous by a post-fence sentinel
/// that must show). The live leak is a **timing race**: upstream dinv arms the
/// omit-from-output item trigger only when its START trigger *matches the column
/// header* (`dbot.wish.setupFn`), so if that header reaches output before the
/// trigger is live — the post-login probe burst, or trigger teardown from a
/// mid-probe reload — the gag never arms and the whole list prints. D-77 arms the
/// item trigger up front in `setupFn` (before `wish list` is sent), closing the
/// race; `wishBodyGaggedWhenHeaderUnmatched` proves it by replaying a header that
/// can never match (gagged with the fix; reverting the one line leaks the lot).
///
/// Observation model: a gagged line is **dropped** from the scrollback; a shown
/// line lands in it. So leakage == a wish line appearing in `scrollbackStore`.
@Suite("dinv — wish-list gag (real session)", .serialized)
struct DinvWishGagTests {
    /// The `wish list` column header + body as dinv's triggers expect it (the
    /// header pattern is `Base…Cost…Adjustment…Your…Cost…Keyword`; item rows end
    /// `-- <Keyword>`). From the header onward dinv gags every line through its
    /// `DINV wish list fence`.
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
    private func runWishFlow(wishLines: [String]) async throws -> [String] {
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

        var answered = Set<String>()
        let deadline = ContinuousClock.now.advanced(by: .seconds(18))
        var tick = 0
        while ContinuousClock.now < deadline {
            tick += 1
            if tick % 25 == 0 {
                await controller.dispatchGMCP(GMCPMessage(
                    package: "char.status", json: #"{"level":150,"state":3,"pos":"Standing"}"#
                ))
            }
            for line in conn.sentLines {
                guard answered.insert(line).inserted else { continue }
                // A command can be glued to a preceding GMCP subnegotiation in one
                // TCP flush (`<IAC…config prompt off…IAC SE>pagesize`), so match the
                // *trailing* command, not the whole line.
                if let r = line.range(of: "echo { DINV fence") {
                    conn.injectLine(String(line[r.lowerBound...].dropFirst("echo ".count)))
                } else if line.hasSuffix("wish list") {
                    for body in wishLines {
                        conn.injectLine(body)
                    }
                    conn.injectLine("DINV wish list fence")
                    // Non-vacuity sentinel: a normal line after the fence MUST show.
                    conn.injectLine("PROTELES_SENTINEL_AFTER_FENCE")
                } else if line.hasSuffix("pagesize 0") {
                    conn.injectLine("Paging disabled.")
                } else if line.hasSuffix("pagesize 20") {
                    conn.injectLine("Page size set to 20 lines.")
                } else if line.hasSuffix("pagesize") {
                    conn.injectLine("You currently display 20 lines per page.")
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

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
        await controller.disconnect()
        // Scrollback text is ANSI-stripped, so compare against stripped wish lines.
        let strippedWishes = Set(wishLines.map(Self.stripANSI))
        return shown.filter { strippedWishes.contains($0) || $0 == "DINV wish list fence" }
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
        let leaked = try await runWishFlow(wishLines: Self.body)
        #expect(leaked.isEmpty, "wish-list body leaked to the user: \(leaked)")
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
        let leaked = try await runWishFlow(wishLines: Self.colouredBody)
        #expect(leaked.isEmpty, "coloured wish rows leaked to the user: \(leaked)")
    }

    /// The live leak's failure mode (D-70/D-77): the column header reaches output
    /// before dinv's START trigger is live (post-login burst, or trigger teardown
    /// from a mid-probe reload), so the header never matches and — with the old
    /// header-gated approach — the omit-from-output item trigger never arms and the
    /// whole list prints. Here the replayed header is deliberately mangled so it
    /// can NEVER match `Base…Cost…Adjustment…Your…Cost…Keyword`; the gag must still
    /// hold because `setupFn` now arms the item trigger up front (D-77). Pre-fix
    /// this leaks the entire list.
    @Test("dinv gags the wish-list even if the header never matches (race)", .timeLimit(.minutes(1)))
    func wishBodyGaggedWhenHeaderUnmatched() async throws {
        var mangled = Self.body
        mangled[0] = "  <<< some unexpected pre-header banner the start trigger can't match >>>"
        let leaked = try await runWishFlow(wishLines: mangled)
        #expect(leaked.isEmpty, "wish-list leaked when header didn't match: \(leaked)")
    }
}
