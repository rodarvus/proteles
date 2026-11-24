import Foundation

/// Occupants (S0b item 2, #84; `docs/plans/S0B_ITEM2_PROPOSAL.md`): presence
/// from `{roomchars}`, names from `consider` and `{scan}`'s `Right here`
/// section, keywords from ``MobKeywordBook``. Every path reports
/// ``ActionableState/Entity/occupants`` only when ``ActionableState/occupants``
/// actually changed, so the heartbeat's identical `{roomchars}` blocks wake no
/// plugin.
extension ActionableStateTracker {
    /// A whole-room `consider` is being sent: read its output.
    public mutating func noteRoomConsider(at date: Date = Date()) {
        considerWindow.open(at: date)
        isReading = true
    }

    /// Replace the keyword book (loaded on connect), re-resolving the named
    /// mobs.
    public mutating func setKeywordBook(_ book: MobKeywordBook) -> Change {
        state.keywords = book
        return rekeyed()
    }

    /// Set (or clear, with `nil`) the player's keyword for `name` in `area`.
    public mutating func setKeywordOverride(_ keyword: String?, for name: String, area: String) -> Change {
        guard state.keywords.setOverride(keyword, for: name, area: area) else { return .none }
        return rekeyed()
    }

    // MARK: - Feeds

    mutating func ingestBlock(_ block: TagBlockCollector.Block, at date: Date) -> Change {
        switch block.feed {
        case .roomchars:
            let present = block.lines.map { Occupant.parse($0.text) }
            return updateOccupants { occupants in
                if occupants.present != present {
                    occupants.present = present
                    occupants.since = date
                }
            } creating: {
                Occupants(present: present, since: date)
            }
        case .scan:
            guard let mobs = ScanHere.mobs(in: block.lines) else { return .none }
            // `consider` sees what scan misses (noscan mobs), so a scan never
            // replaces a consider list for the same room.
            if let named = state.occupants?.named, named.source == .consider, named.room == room.num {
                return .none
            }
            return setNamed(
                .scan,
                mobs.map { NamedMob(name: $0.name, flags: $0.flags) },
                at: date
            )
        default:
            return .none
        }
    }

    mutating func ingestConsider(_ line: Line) -> Change {
        guard case .completed(let run) = considerWindow.ingest(line.text, at: line.timestamp)
        else { return .none }
        state.countBlock(.consider, at: line.timestamp)
        let mobs = run.filter { !$0.isPlayer }
            .map { NamedMob(name: $0.name, flags: $0.flags, tier: $0.tier, unattackable: $0.unattackable) }
        var change = setNamed(.consider, mobs, at: line.timestamp)
        change.state = true
        return change
    }

    // MARK: - Helpers

    /// A named mob before its keyword is resolved.
    private struct NamedMob {
        let name: String
        let flags: [String]
        var tier: ConsiderTier?
        var unattackable: ConsiderLine.Unattackable?
    }

    private mutating func setNamed(
        _ source: NamedOccupants.Source,
        _ mobs: [NamedMob],
        at date: Date
    ) -> Change {
        let named = NamedOccupants(
            source: source,
            room: room.num,
            area: room.area,
            at: date,
            mobs: mobs.map { mob in
                NamedOccupant(
                    name: mob.name,
                    flags: mob.flags,
                    tier: mob.tier,
                    unattackable: mob.unattackable,
                    keyword: state.keywords.resolve(mob.name, area: room.area)
                )
            }
        )
        // Names before any `{roomchars}`: presence stays unknown.
        return updateOccupants { occupants in
            occupants.named = named
            occupants.since = date
        } creating: {
            Occupants(present: nil, since: date, named: named)
        }
    }

    /// The book changed: re-resolve the named mobs' keywords.
    private mutating func rekeyed() -> Change {
        var change = Change(state: true, entities: [.keywords])
        guard let named = state.occupants?.named else { return change }
        let book = state.keywords
        change.merge(updateOccupants { occupants in
            for index in named.mobs.indices {
                occupants.named?.mobs[index].keyword = book.resolve(named.mobs[index].name, area: named.area)
            }
        } creating: { nil })
        return change
    }

    /// Apply `update` to the occupants (or `create` them), reporting the
    /// entity only when they changed.
    private mutating func updateOccupants(
        _ update: (inout Occupants) -> Void,
        creating create: () -> Occupants?
    ) -> Change {
        let before = state.occupants
        if var occupants = state.occupants {
            update(&occupants)
            state.occupants = occupants
        } else {
            state.occupants = create()
        }
        guard state.occupants != before else { return .none }
        return Change(state: true, entities: [.occupants])
    }
}
