import Foundation

// The verified ground truth for the native Consider feature, ported verbatim
// from the canonical MUSHclient plugin (AardCrowley/Mushclient-Consider, a fork
// of Athlau's "Consider all miniwindow"): the difficulty tiers Aardwolf's
// `consider all` emits, the room-movement / kill / flee line patterns, the
// name→keyword stripping fallback, and the level-range parser the batch filter
// uses.
//
// **No guessing.** Every phrase, colour, range label, and regex here is copied
// from the plugin's `Aardwolf_Consider_Miniwin.xml` triggers and
// `Name_Cleanup.lua`; the per-tier `<send>` blocks set `mob_color`/`mob_range`
// exactly as reproduced below. Do not edit a value here without re-checking it
// against that source.

/// One difficulty tier of `consider all` output: the phrase Aardwolf prints when
/// you consider a mob that much above/below your effective level, plus the colour
/// and human range label the plugin assigns it.
///
/// Every tier regex has the same shape — `^(\(.+\) ?)?…(.+)…$` — where capture
/// **group 1** is the optional leading aura flags (`(Red Aura) `, `(R) `, …) and
/// **group 2** is the mob's display name. That uniformity (verified across all
/// 13 triggers) lets one matcher handle them all.
public struct ConsiderTier: Sendable, Equatable {
    /// MUSHclient colour name the plugin renders this tier in (e.g. `"crimson"`).
    /// Kept as the literal name; the UI maps names → colours.
    public let colour: String
    /// The human range label shown in the panel, verbatim from the plugin
    /// (e.g. `"+16 to +20"`, `"-20 and below"`, `"+51 and above"`).
    public let rangeLabel: String
    /// The anchored ICU regex matching this tier's `consider all` line.
    public let pattern: String

    /// The inclusive level bounds `rangeLabel` represents, computed the same way
    /// the plugin's `ShouldSkipMob` does: parse `"X to Y"` (swapping if reversed),
    /// or apply the two open-ended special cases. Used only for the batch filter.
    public var bounds: ClosedRange<Int> {
        ConsiderTier.parseRangeBounds(rangeLabel)
    }

    /// Replicates `ShouldSkipMob`'s range parsing exactly (including the literal
    /// `+51 and above → 50…300`, which the plugin sets to 50 not 51).
    public static func parseRangeBounds(_ label: String) -> ClosedRange<Int> {
        if let match = label.range(of: #"([+-]?\d+) to ([+-]?\d+)"#, options: .regularExpression) {
            let parts = label[match].components(separatedBy: " to ")
            if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
                return min(low, high)...max(low, high)
            }
        }
        if label.contains("-20 and below") { return -300...(-20) }
        if label.contains("+51 and above") { return 50...300 }
        return -300...300
    }

    /// All 13 tiers, in the plugin's trigger order. `consider all` emits one line
    /// per mob; the matching tier supplies its colour + range.
    public static let all: [ConsiderTier] = [
        ConsiderTier(
            colour: "gray",
            rangeLabel: "-20 and below",
            pattern: #"^(\(.+\) )?You would stomp (.+) into the ground\.$"#
        ),
        ConsiderTier(
            colour: "darkgreen",
            rangeLabel: "-10 to -19",
            pattern: #"^(\(.+\) ?)?(.+) would be easy, but is it even worth the work out\?$"#
        ),
        ConsiderTier(
            colour: "forestgreen",
            rangeLabel: "-5 to -9",
            pattern: #"^(\(.+\) ?)?No Problem! (.+) is weak compared to you\.$"#
        ),
        ConsiderTier(
            colour: "chartreuse",
            rangeLabel: "-2 to -4",
            pattern: #"^(\(.+\) ?)?(.+) looks a little worried about the idea\.$"#
        ),
        ConsiderTier(
            colour: "springgreen",
            rangeLabel: "-1 to +1",
            pattern: #"^(\(.+\) ?)?(.+) should be a fair fight!$"#
        ),
        ConsiderTier(
            colour: "darkgoldenrod",
            rangeLabel: "+2 to +4",
            pattern: #"^(\(.+\) ?)?(.+) snickers nervously\.$"#
        ),
        ConsiderTier(
            colour: "gold",
            rangeLabel: "+5 to +9",
            pattern: #"^(\(.+\) ?)?(.+) chuckles at the thought of you fighting"#
        ),
        ConsiderTier(
            colour: "tomato",
            rangeLabel: "+10 to +15",
            pattern: #"^(\(.+\) ?)?Best run away from (.+) while you can!$"#
        ),
        ConsiderTier(
            colour: "crimson",
            rangeLabel: "+16 to +20",
            pattern: #"^(\(.+\) ?)?Challenging (.+) would be either very brave or very stupid\.$"#
        ),
        ConsiderTier(
            colour: "lightpink",
            rangeLabel: "+21 to +30",
            pattern: #"^(\(.+\) ?)?(.+) would crush you like a bug!$"#
        ),
        ConsiderTier(
            colour: "darkmagenta",
            rangeLabel: "+31 to +41",
            pattern: #"^(\(.+\) ?)?(.+) would dance on your grave!$"#
        ),
        ConsiderTier(
            colour: "darkviolet",
            rangeLabel: "+41 to +50",
            pattern: #"^(\(.+\) ?)?(.+) says 'BEGONE FROM MY SIGHT unworthy!'$"#
        ),
        ConsiderTier(
            colour: "magenta",
            rangeLabel: "+51 and above",
            pattern: #"^(\(.+\) ?)?You would be completely annihilated by (.+)!$"#
        )
    ]
}

/// Aardwolf line patterns the plugin tracks between `consider all` runs to keep
/// the list live: mobs walking out / arriving, fleeing, and dying. Capture group
/// 1 is the mob name in each. Ported from the plugin's `track_mob_moves` /
/// `auto_track_kills` trigger groups.
public enum ConsiderLinePatterns {
    /// Movement verbs the plugin's departure trigger recognises.
    private static let leaveVerbs = [
        "skulks", "swims", "flies", "hops", "leaves", "glides", "jets", "walks",
        "dashes", "slinks", "crashes", "lopes", "floats", "wanders", "strides",
        "scurries", "stumbles", "runs", "skitters"
    ].joined(separator: "|")

    /// Movement verbs the arrival trigger recognises (a near-superset).
    private static let arriveVerbs = [
        "skulks", "swims", "flies", "arrives", "glides", "jets", "walks", "canters",
        "charging", "slinks", "crashes", "lopes", "floats", "wanders", "strides",
        "scurries", "stumbles", "runs", "skitters"
    ].joined(separator: "|")

    private static let exitDirections = "north|south|east|west|up|down"
    private static let arriveDirections = "north|south|east|west|above|below"

    /// A mob leaving by an exit: `"<name> <verb> <direction>."`.
    public static let mobLeft = #"^(.+) (?:\#(leaveVerbs)) (?:\#(exitDirections)).$"#

    /// A mob arriving from a direction.
    public static let mobArrivedFrom =
        #"^(.+) (?:\#(arriveVerbs)) (?:in )?from (?:the )?(?:\#(arriveDirections)).$"#

    /// A mob appearing in the room (summon / portal / thunderclap).
    public static let mobAppeared =
        #"^(?:With a thunderclap, )?(.+) appears in the room\.$"#

    /// A mob fleeing.
    public static let mobFled = #"^(.+) has fled!$"#

    /// The death messages the plugin matches (capture group 1 = victim name),
    /// covering the standard kill plus the magic/elemental variants.
    public static let kills: [String] = [
        #"^(.*) \w+ (?:is|are) DEAD!$"#,
        #"^(.*) (?:is|are) DEAD!!$"#,
        #"^(.*) falls dead as \w+ mind is destroyed!!$"#,
        #"^The voice of god has cleansed (.*) eternally! \w+ is DEAD!$"#,
        #"^(.*) howls as \w+ last spark of life is drained!!$"#,
        #"^(.*) turns deadly pale and collapses!!$"#,
        #"^The mind force crushes (.*) into a bloody pulp! \w+ is DEAD!$"#,
        #"^(.*) screams in agony as the acid consumes \w+!!$"#,
        #"^(.*) is damned forever by the holy power!!$"#,
        #"^(.*) screams as the flames engulf \w+!!$"#,
        #"^(.*) is battered to death by the force of the water!$"#,
        #"^(.*) crumbles as \w+ is battered to death!!$"#,
        #"^(.*) smoulders as the lightning destroys \w+!!$"#,
        #"^(.*) is slain by a final .*!!$"#
    ]
}

/// The name→keyword stripping fallback, ported from the plugin's
/// `Name_Cleanup.lua` `Stripname`. Used when no Search-and-Destroy plugin is
/// available to resolve a better keyword. Strips articles/prepositions/possessives
/// and punctuation, with the citadel-area title special-case.
public enum ConsiderNameCleanup {
    /// Ordered (pattern, replacement) rewrites mirroring `Stripname`'s gsubs.
    /// Patterns are ICU regex; `^` anchors are intentional where the Lua used
    /// them. Lua character classes `[Aa]`/`[Ff]`/`[Tt]` become explicit groups.
    private static let rewrites: [(pattern: String, replacement: String)] = [
        (#"^[aA] "#, ""),
        (#"^[Aa]n "#, ""),
        (#"^[Tt]he "#, ""),
        (#"[Ff]rom "#, ""),
        (#" on "#, " "),
        (#" in "#, " "),
        (#" a "#, " "),
        (#" an "#, " "),
        (#" with "#, " "),
        (#" and "#, " "),
        (#" of "#, " "),
        (#" [Tt]he "#, " "),
        (#"'s "#, " "),
        (#", "#, " "),
        (#"-"#, " ")
    ]

    /// Strip `name` to a targeting keyword. `zone` enables the citadel-only
    /// title trimming (matching the plugin's `gmcp("room.info.zone")` check).
    public static func strip(_ name: String, zone: String? = nil) -> String {
        var result = name
        if zone == "citadel" {
            for suffix in [#" prince of .*"#, #" princess of .*"#, #" archangel of .*"#] {
                result = result.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
            }
        }
        for (pattern, replacement) in rewrites {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // Pull out ? ! " and , (the plugin's while-loop; one pass suffices since
        // each is a literal single-character removal).
        result = result.replacingOccurrences(of: #"[?!",]"#, with: "", options: .regularExpression)
        // ". " → " " (e.g. trailing initials).
        result = result.replacingOccurrences(of: #"\. "#, with: " ", options: .regularExpression)
        return result
    }
}
