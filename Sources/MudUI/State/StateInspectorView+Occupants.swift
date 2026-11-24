import Foundation
import MudCore
import SwiftUI

/// The State inspector's Occupants section (S0b item 2, #84): presence from
/// `{roomchars}`, the named list with its source and completeness, and each
/// name's keyword and where it came from. Players are counted, never named.
struct StateInspectorOccupantsSection: View {
    let occupants: Occupants?

    var body: some View {
        let summary = StateInspectorOccupants(occupants)
        Section {
            ForEach(summary.lines, id: \.self) { text in
                Text(text).font(.body.monospaced())
            }
            LabeledContent("Names", value: summary.namesStatus)
            ForEach(summary.named, id: \.self) { row in
                LabeledContent {
                    Text(row.keyword).font(.body.monospaced())
                } label: {
                    Text(row.name)
                    Text(row.detail)
                }
            }
        } header: {
            Text("Occupants")
        } footer: {
            Text(summary.footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The occupants as the inspector lists them. Pure, so it is tested without
/// a view.
public struct StateInspectorOccupants: Sendable, Equatable {
    /// One named mob: its name, `'keyword'`, and tier and keyword source.
    public struct Named: Sendable, Hashable {
        public let name: String
        public let keyword: String
        public let detail: String
    }

    /// The present mobs (flags and description), or a single line saying
    /// presence isn't known.
    public let lines: [String]
    /// "consider, 4 mobs, complete" and similar.
    public let namesStatus: String
    public let named: [Named]
    public let footer: String

    public init(_ occupants: Occupants?, timeZone: TimeZone = .current) {
        guard let occupants else {
            lines = ["Not known: no {roomchars}, consider or scan this connection."]
            namesStatus = "None"
            named = []
            footer = Self.footerText
            return
        }
        if let mobs = occupants.mobs {
            lines = mobs.map { mob in
                (mob.flags.map { "(\($0))" }.joined() + " " + mob.description)
                    .trimmingCharacters(in: .whitespaces)
            } + ["Players present: \(occupants.playerCount ?? 0)"]
        } else {
            lines = ["Presence not known: {roomchars} hasn't arrived."]
        }
        if let list = occupants.named {
            let completeness = occupants.present == nil ? "presence unknown"
                : occupants.isNamedComplete ? "complete" : "partial"
            namesStatus = "\(list.source.rawValue) at \(Self.time(list.at, timeZone)), "
                + "\(list.mobs.count) \(list.mobs.count == 1 ? "mob" : "mobs"), \(completeness)"
            named = list.mobs.map { mob in
                let level = mob.tier?.rangeLabel ?? mob.unattackable?.label ?? "no tier (scan)"
                return Named(
                    name: mob.name,
                    keyword: "'\(mob.keyword.keyword)'",
                    detail: "\(level) · keyword \(Self.text(mob.keyword.source))"
                )
            }
        } else {
            namesStatus = "None for this room"
            named = []
        }
        footer = Self.footerText
    }

    private static let footerText = "Presence is {roomchars} (descriptions, not names). Names come from any "
        + "whole-room consider or a scan's “Right here” section, and are complete when they count as many "
        + "mobs as are present. Set a keyword with `conw kw <n> <keyword>`."

    private static func text(_ source: MobKeywordBook.Source) -> String {
        switch source {
        case .player: "set by you"
        case .snd: "from S&D"
        case .guess: "guessed"
        }
    }

    private static func time(_ date: Date, _ timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .standard)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}
