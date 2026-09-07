import Foundation
@testable import MudCore
import Testing

/// The tag-family router (S0a item 5, GitHub #82, D-123).
///
/// Every tagged line asserted here is **verbatim from the recordings corpus**
/// (`docs/AARDWOLF_DATA_FEEDS.md` §8 — fixtures come from the corpus, never
/// from the author's idea of the format); provenance is noted per case. The
/// reason table is pinned to `help spelltags` as captured on 2026-08-22.
@Suite("AardwolfTags — the tag-family router")
struct AardwolfTagRouterTests {
    // MARK: - The family list is the closed list from the `tags` command

    /// `session-20260822-141044.log`, the bare `tags` command: 27 families.
    /// S0b adds parsers to this list; nothing adds to the list but Aardwolf.
    @Test("Family names every family the tags command lists")
    func familyIsTotal() {
        let fromTagsCommand = Set([
            "bigmap", "channels", "coords", "editors", "equip", "exits", "helps", "inv",
            "map", "mapexits", "mapnames", "quiet", "roomdescs", "roomnames", "says",
            "score", "skillgains", "spellups", "tells", "telopts", "mapdata", "roomchars",
            "roomobjs", "scan", "repop", "commands", "where"
        ])
        #expect(Set(AardwolfTags.Family.allCases.map(\.rawValue)) == fromTagsCommand)
        #expect(AardwolfTags.Family.allCases.count == 27)
    }

    /// Every marker the map knows resolves to a listed family, and the six
    /// event markers land in the two families this item routes.
    @Test("Every mapped marker belongs to a listed family; event markers to SPELLUPS/SKILLGAINS")
    func markerMapIsConsistent() {
        for (marker, family) in AardwolfTags.familiesByMarker {
            #expect(AardwolfTags.Family.allCases.contains(family), "\(marker) → \(family)")
        }
        for marker in ["affon", "affoff", "recon", "recoff", "sfail"] {
            #expect(AardwolfTags.familiesByMarker[marker] == .spellups, "\(marker)")
        }
        #expect(AardwolfTags.familiesByMarker["skillgain"] == .skillgains)
    }

    /// D-123: comms are GMCP. The comm markers are *known* (so a stray one is
    /// recognised as a tag, not prose) but the router never emits for them.
    @Test("Comm families are recognised as tags and never routed to events")
    func commFamiliesAreNeverRouted() {
        for line in ["{chan ch=tech}Bob techs 'hi'", "{tell}Bob tells you 'hi'", "{say}Bob says 'hi'"] {
            let marker = AardwolfTags.marker(in: line)
            #expect(marker?.family != nil, "\(line)")
            #expect(AardwolfTags.events(forTagged: line).isEmpty, "\(line)")
        }
    }

    // MARK: - Markers

    /// `session-20260822-141044.log`: an open marker, its family, its payload.
    @Test("marker(in:) reads name, family, closing flag and payload")
    func markerParsing() throws {
        let affon = try #require(AardwolfTags.marker(in: "{affon}259,2655"))
        #expect(affon.name == "affon")
        #expect(affon.family == .spellups)
        #expect(affon.isClosing == false)
        #expect(affon.payload == "259,2655")

        let closing = try #require(AardwolfTags.marker(in: "{/roomchars}"))
        #expect(closing.name == "roomchars")
        #expect(closing.isClosing)
        #expect(closing.payload.isEmpty)

        // Command output tagged regardless of the `tags` command: a marker, no family.
        let invdata = try #require(AardwolfTags.marker(in: "{invdata 123}"))
        #expect(invdata.name == "invdata")
        #expect(invdata.family == nil)

        #expect(AardwolfTags.marker(in: "You raise a level!") == nil)
        #expect(AardwolfTags.marker(in: "{ DINV fence 5 }") == nil) // dinv's fence is not a tag
    }

    // MARK: - The six events, from corpus lines

    /// `session-20260822-141044.log` line 3690: `{affon}259,2655` right after
    /// "You feel yourself moving at the speed of light!".
    @Test("{affon} → affect_on with spell and seconds, tag-sourced, affect category")
    func affectOn() throws {
        let event = try #require(AardwolfTags.events(forTagged: "{affon}259,2655").first)
        #expect(event.name == "affect_on")
        #expect(event.category == .affect)
        #expect(event.source == .tag(family: "spellups"))
        #expect(event.source.durability == 1)
        #expect(event.payload == ["spell": "259", "seconds": "2655"])
    }

    /// `session-20260822-141044.log` line 3683: `{affoff}259` after
    /// "You no longer move at the speed of light."
    @Test("{affoff} → affect_off")
    func affectOff() throws {
        let event = try #require(AardwolfTags.events(forTagged: "{affoff}259").first)
        #expect(event.name == "affect_off")
        #expect(event.category == .affect)
        #expect(event.payload == ["spell": "259"])
    }

    /// Corpus-wide: `{recon}2,494` (16 occurrences) and `{recoff}2` (199);
    /// `{recoff}0` occurs once and is a legitimate recovery number.
    @Test("{recon}/{recoff} → recovery_on/recovery_off, including recovery 0")
    func recoveries() throws {
        let on = try #require(AardwolfTags.events(forTagged: "{recon}2,494").first)
        #expect(on.name == "recovery_on")
        #expect(on.payload == ["recovery": "2", "seconds": "494"])
        let off = try #require(AardwolfTags.events(forTagged: "{recoff}2").first)
        #expect(off.name == "recovery_off")
        #expect(off.payload == ["recovery": "2"])
        let zero = try #require(AardwolfTags.events(forTagged: "{recoff}0").first)
        #expect(zero.payload == ["recovery": "0"])
    }

    /// Corpus-wide: `{sfail}104,0,2,-1` (535 occurrences) — spell 104 on self,
    /// reason 2 (already affected), no recovery. The `-1` must not leak into
    /// the payload as a recovery number.
    @Test("{sfail} → cast_failed with a named reason; -1 means no recovery")
    func castFailed() throws {
        let event = try #require(AardwolfTags.events(forTagged: "{sfail}104,0,2,-1").first)
        #expect(event.name == "cast_failed")
        #expect(event.category == .affect)
        #expect(event.payload == [
            "spell": "104", "target": "self", "reason": "2", "reasonName": "already_affected"
        ])
        #expect(event.payload["recovery"] == nil)
    }

    /// `help spelltags`: reason 3 is "cast blocked by a recovery", and then the
    /// fourth field carries the recovery number.
    @Test("{sfail} reason 3 carries the blocking recovery; target 1 is other")
    func castFailedBlockedByRecovery() throws {
        let event = try #require(AardwolfTags.events(forTagged: "{sfail}72,1,3,15").first)
        #expect(event.payload["target"] == "other")
        #expect(event.payload["reasonName"] == "blocked_by_recovery")
        #expect(event.payload["recovery"] == "15")
    }

    /// The reason table, code by code, as `help spelltags` lists it. Code 7 is
    /// absent in the help and must resolve to `unknown` — not to a neighbour.
    @Test("The cast-failure reason table matches help spelltags; 7 is unknown")
    func reasonTable() {
        let expected: [Int: String] = [
            1: "lost_concentration", 2: "already_affected", 3: "blocked_by_recovery",
            4: "not_enough_mana", 5: "nocast_room", 6: "cannot_concentrate",
            8: "unknown_spell", 9: "self_only_on_other", 10: "resting",
            11: "disabled", 12: "not_enough_moves"
        ]
        #expect(AardwolfTags.castFailureReasons == expected)
        let seven = AardwolfTags.events(forTagged: "{sfail}72,0,7,-1").first
        #expect(seven?.payload["reasonName"] == "unknown")
        #expect(seven?.payload["reason"] == "7")
    }

    /// Corpus-wide: `{skillgain}223,99` — skill 223 now at 99 %.
    @Test("{skillgain} → skill_gain, progression category, tag-sourced")
    func skillGain() throws {
        let event = try #require(AardwolfTags.events(forTagged: "{skillgain}223,99").first)
        #expect(event.name == "skill_gain")
        #expect(event.category == .progression)
        #expect(event.source == .tag(family: "skillgains"))
        #expect(event.payload == ["skill": "223", "percent": "99"])
    }

    // MARK: - What yields nothing

    /// A payload that does not match the documented shape yields no event:
    /// the router does not guess (`AARDWOLF_DATA_FEEDS.md` §9).
    @Test("Malformed or undocumented payloads yield no event")
    func malformedYieldsNothing() {
        #expect(AardwolfTags.events(forTagged: "{affon}abc").isEmpty)
        #expect(AardwolfTags.events(forTagged: "{affon}259").isEmpty) // one field, needs two
        #expect(AardwolfTags.events(forTagged: "{affoff}").isEmpty)
        #expect(AardwolfTags.events(forTagged: "{sfail}72,5,2,-1").isEmpty) // target must be 0/1
        #expect(AardwolfTags.events(forTagged: "{sfail}72,0,2").isEmpty) // needs four fields
    }

    /// Entity-feed markers (S0b), closing markers, command output and prose all
    /// route to nothing in S0a.
    @Test("Entity markers, closing markers, command output and prose yield no event")
    func outOfScopeYieldsNothing() {
        for line in [
            "{rname}The top of the tower", "{coords}4,6,20", "{roomchars}", "{/roomchars}",
            "{exits}", "{invmon}1,123,-1,0", "{invdata 123}", "{spellheaders learned}",
            "You raise a level! You are now level 100.", ""
        ] {
            #expect(AardwolfTags.events(forTagged: line).isEmpty, "\(line)")
        }
    }

    // MARK: - Display is untouched

    /// Routing and display are independent. Pinned to today's behaviour:
    /// machine-data families stay hidden, prose-carrying markers are stripped.
    @Test("displayLine(for:) is unchanged for routed lines")
    func displayUnchanged() {
        let hidden = AardwolfTags.displayLine(for: Line(id: LineID(0), text: "{affoff}259"))
        #expect(hidden == nil, "machine data stays hidden")
        let sfail = AardwolfTags.displayLine(for: Line(id: LineID(0), text: "{sfail}104,0,2,-1"))
        #expect(sfail == nil)
        let stripped = AardwolfTags.displayLine(for: Line(id: LineID(0), text: "{rname}The top of the tower"))
        #expect(stripped?.text == "The top of the tower")
    }
}

/// The classification point and the engine seam (Option B, `43bd3dcd`): tag
/// events ride the same guard and the same disposition as prose events.
@Suite("AardwolfTags — routed through the classifier and the engine")
struct AardwolfTagRouterWiringTests {
    /// A listener that records what it is handed, as effects the test can read.
    private struct Listener: NativePlugin {
        let metadata = NativePluginMetadata(
            id: "com.proteles.test.listener",
            name: "Listener",
            author: "test",
            version: "1",
            summary: "records semantic events"
        )
        var wantsSemanticEvents: Bool {
            true
        }

        func onSemanticEvent(_ event: SemanticEvent) -> [ScriptEffect] {
            var family = ""
            if case .tag(let name) = event.source { family = name }
            return [.echo("event:\(event.name):\(family)")]
        }
    }

    /// The single classification point produces tag events beside prose events.
    @Test("SemanticClassifier emits tag events for tagged lines and none for prose")
    func classifierRoutesTags() {
        let tagged = SemanticClassifier.events(forDisplayedText: "{affon}259,2655")
        #expect(tagged.map(\.name) == ["affect_on"])
        let prose = SemanticClassifier.events(forDisplayedText: "You raise a level! You are now level 100.")
        #expect(prose.map(\.name) == ["level_up"])
        #expect(prose.allSatisfy { $0.source.durability == 2 }, "prose events are pattern-sourced")
    }

    /// Guard order, the lesson of the first wiring attempt: with nobody
    /// listening the engine publishes nothing for a tag line.
    @Test("With no listener a tag line yields no semantic effects")
    func noListenerNoEffects() async throws {
        let engine = try ScriptEngine()
        let disposition = await engine.process(line: "{affoff}259")
        #expect(disposition.semanticEffects.isEmpty)
    }

    /// With a listener, the event arrives tag-sourced through the existing
    /// disposition — no new seam, no new hop.
    @Test("With a listener a tag line's event reaches the plugin, tag-sourced")
    func listenerReceivesTagEvent() async throws {
        let engine = try ScriptEngine()
        await engine.registerNativePlugin(Listener())
        let disposition = await engine.process(line: "{sfail}104,0,2,-1")
        #expect(disposition.semanticEffects == [.echo("event:cast_failed:spellups")])
        let prose = await engine.process(line: "You raise a level! You are now level 100.")
        #expect(prose.semanticEffects == [.echo("event:level_up:")])
    }
}
