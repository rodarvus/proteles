import Foundation

// The verified ground truth for the native Consider feature, ported verbatim
// from the canonical MUSHclient plugin (AardCrowley/Mushclient-Consider, a fork
// of Athlau's "Consider all miniwindow"): the kill line patterns and the
// name→keyword stripping fallback. The difficulty tiers
// themselves are shared with the state model (`Semantic/State/ConsiderTier.swift`).
//
// **No guessing.** Every phrase and regex here is copied from the plugin's
// `Aardwolf_Consider_Miniwin.xml` triggers and `Name_Cleanup.lua`. Do not edit
// a value here without re-checking it against that source.

/// The kill lines the plugin tracks between `consider all` runs to keep the
/// list live. Capture group 1 is the mob name in each. Ported from the
/// plugin's `auto_track_kills` trigger group. Mobs moving in, out and fleeing
/// are ``ConsiderMovement``'s: the recordings have more movement verbs than
/// the plugin lists.
public enum ConsiderLinePatterns {
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
