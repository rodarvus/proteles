import Foundation

// The difficulty tiers Aardwolf's `consider` emits, ported verbatim from the
// canonical MUSHclient plugin (AardCrowley/Mushclient-Consider, a fork of
// Athlau's "Consider all miniwindow") and re-checked against `help consider`
// (2026-10-30: the 13 messages and level ranges match). Shared by the
// Consider feature and the state model's named occupants (S0b item 2, #84),
// so the patterns exist once.
//
// **No guessing.** Every phrase, colour, range label, and regex here is copied
// from the plugin's `Aardwolf_Consider_Miniwin.xml` triggers; the per-tier
// `<send>` blocks set `mob_color`/`mob_range` exactly as reproduced below. Do
// not edit a value here without re-checking it against that source.

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
