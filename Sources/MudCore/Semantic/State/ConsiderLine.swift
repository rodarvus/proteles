import Foundation

/// One line of `consider` output: a mob's name, its aura flags, and either
/// its difficulty tier or why it can't be attacked (S0b item 2, #84).
///
/// The 13 tiers are ``ConsiderTier/all`` (`help consider`). The
/// unattackable lines aren't in the help. Divine protection and the
/// shopkeeper are Search-and-Destroy's `consider_protected` and
/// `consider_shopkeeper` triggers; the popular consider plugin
/// (`Aardwolf_Consider_Miniwin.xml`) adds the god's disapproval and
/// smiting, and a mob already challenged. Each stands for one mob in the
/// list, so a room's count includes them; the recordings have every one
/// but smiting, which only that plugin documents.
public struct ConsiderLine: Sendable, Equatable {
    /// Why a considered mob can't be attacked.
    public enum Unattackable: String, Sendable, Codable {
        case divineProtection, shopkeeper
        /// `Ayla would not approve of you killing Commander Dahr!`
        case wouldNotApprove
        /// `<god> would smite you for killing <mob>!`
        case wouldSmite
        /// `A hungry rat has already been challenged.` The game prints the
        /// same line when such a mob is attacked; inside a consider run it
        /// is the mob's entry.
        case alreadyChallenged

        /// How the Consider panel and the State inspector name the reason.
        public var label: String {
            switch self {
            case .divineProtection: "divine protection"
            case .shopkeeper: "shopkeeper"
            case .wouldNotApprove: "a god would not approve"
            case .wouldSmite: "a god would smite you"
            case .alreadyChallenged: "already challenged"
            }
        }
    }

    public let name: String
    /// The aura flags as written (`(R) `), for the Consider panel and its
    /// batch filter.
    public let rawFlags: String
    public let flags: [String]
    /// Nil for an unattackable mob.
    public let tier: ConsiderTier?
    public let unattackable: Unattackable?

    public var isPlayer: Bool {
        AuraFlags.isPlayer(flags)
    }

    /// The `consider` line `text` is, if it is one.
    public static func parse(_ text: String) -> ConsiderLine? {
        guard needles.contains(where: { text.contains($0) }) else { return nil }
        for entry in matchers.tiers {
            if let line = line(text, entry.matcher, tier: entry.tier, unattackable: nil) { return line }
        }
        for entry in matchers.unattackable {
            if let line = line(text, entry.matcher, tier: nil, unattackable: entry.reason) { return line }
        }
        return nil
    }

    /// Capture 1 is the flags, capture 2 the name, in every pattern.
    private static func line(
        _ text: String, _ matcher: PatternMatcher, tier: ConsiderTier?, unattackable: Unattackable?
    ) -> ConsiderLine? {
        guard let result = matcher.match(text), result.captures.count > 2, !result.captures[2].isEmpty
        else { return nil }
        let rawFlags = result.captures[1]
        return ConsiderLine(
            name: result.captures[2],
            rawFlags: rawFlags,
            flags: AuraFlags.split(Substring(rawFlags)).flags,
            tier: tier,
            unattackable: unattackable
        )
    }

    /// One literal from each pattern: a line containing none of them can't
    /// match, so most lines skip the regexes.
    static let needles = [
        "into the ground.", "worth the work out?", "weak compared to you.", "worried about the idea.",
        "fair fight!", "snickers nervously.", "chuckles at the thought of you fighting", "while you can!",
        "very brave or very stupid.", "like a bug!", "dance on your grave!", "BEGONE FROM MY SIGHT",
        "completely annihilated by", "has divine protection.", "customers?",
        "would not approve of you killing", "would smite you for killing", "has already been challenged."
    ]

    static let unattackablePatterns: [(Unattackable, String)] = [
        (.divineProtection, #"^(\(.+\) ?)?(.+) has divine protection\.$"#),
        (.shopkeeper, #"^(\(.+\) ?)?If you killed (.+), who would serve .+ customers\?$"#),
        (.wouldNotApprove, #"^(\(.+\) ?)?.+ would not approve of you killing (.+)!$"#),
        (.wouldSmite, #"^(\(.+\) ?)?.+ would smite you for killing (.+)!$"#),
        (.alreadyChallenged, #"^(\(.+\) ?)?(.+) has already been challenged\.$"#)
    ]

    private struct Matchers {
        let tiers: [(tier: ConsiderTier, matcher: PatternMatcher)]
        let unattackable: [(reason: Unattackable, matcher: PatternMatcher)]

        // The literals are known-good, so compilation can't fail.
        // swiftlint:disable force_try
        init() {
            tiers = ConsiderTier.all.map {
                ($0, try! PatternMatcher(pattern: .regex($0.pattern), caseSensitive: true))
            }
            unattackable = ConsiderLine.unattackablePatterns.map {
                ($0.0, try! PatternMatcher(pattern: .regex($0.1), caseSensitive: true))
            }
        }
        // swiftlint:enable force_try
    }

    private static let matchers = Matchers()
}
