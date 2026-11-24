import Foundation

/// Auto-refresh (``ConsiderAutoMode``): when the feature sends its own
/// `consider all`. The original's `auto_consider` and `auto_consider_misc`
/// groups refresh on room entry and when a mob appears or flees; Areia's
/// adds the area repop and, in its auto mode, the switch-off on leaving the
/// zone (`conw area` here).
extension ConsiderFeature {
    private var isPlaying: Bool {
        playerState.map(Self.playingStates.contains) ?? false
    }

    /// Whether a refresh may go out now: playing, and not mid-walk. A consider
    /// sent mid-walk waits behind the `run` and is answered in the room the
    /// walk ends in, so a walk to a campaign mob got one per leg there
    /// (session-20261121-084649, 09:42:34–39: three).
    private var canRefresh: Bool {
        isPlaying && !mapperRunning
    }

    /// The mapper's 999 broadcast: a walk started or ended. A refresh that
    /// came due on the way goes out once, in the room the walk ended in (the
    /// end arrives about 0.1 s after the room does). Areia_Consider holds off
    /// on the same broadcast.
    public mutating func onMapperBroadcast(id: Int, text: String) -> [ScriptEffect] {
        guard id == 999 else { return [] }
        mapperRunning = text == "kinda_busy"
        guard !mapperRunning, pendingConsider, isPlaying else { return [] }
        pendingConsider = false
        return settings.auto == .off ? [] : autoConsider()
    }

    /// A refresh deferred while not playing (a room entered or a mob
    /// arriving mid-fight) fires once we're playing again.
    mutating func onCharStatus(_ json: String) -> [ScriptEffect] {
        guard let status = try? JSONDecoder().decode(CharStatus.self, from: Data(json.utf8))
        else { return [] }
        playerAlign = status.align
        let previous = playerState
        playerState = status.state
        guard canRefresh, previous != status.state, pendingConsider else { return [] }
        pendingConsider = false
        return settings.auto == .off ? [] : autoConsider()
    }

    mutating func onRoomInfo(_ json: String) -> [ScriptEffect] {
        guard let room = try? JSONDecoder().decode(RoomInfo.self, from: Data(json.utf8)) else { return [] }
        let movedRooms = room.num != currentRoom
        let previousZone = currentZone
        currentRoom = room.num
        currentZone = room.zone
        isSafeRoom = room.details?.contains("safe") ?? false
        guard movedRooms else { return [] }
        // A new room: the old list no longer applies. A run still in flight
        // is left to finish, so its output stays gagged.
        if !model.considering { model.clear() }
        statusNote = nil
        pendingConsider = false
        let effects = [publishEffect()]
        if settings.auto == .area, let previousZone, previousZone != room.zone {
            settings.auto = .off
            return [.echo("Consider: auto-refresh is off now you've left \(previousZone). "
                    + "`conw area` or `conw on` turns it back on.")]
                + configChanged()
        }
        guard settings.auto != .off else { return effects }
        guard canRefresh else {
            pendingConsider = true
            return effects
        }
        return effects + autoConsider()
    }

    /// `comm.repop` for this area: the room may have new mobs.
    mutating func onRepop(_ json: String) -> [ScriptEffect] {
        struct Repop: Decodable {
            let zone: String?
        }
        guard let repop = try? JSONDecoder().decode(Repop.self, from: Data(json.utf8)),
              repop.zone != nil, repop.zone == currentZone
        else { return [] }
        return refreshIfAuto()
    }

    /// A refresh because who is here changed (an arrival, a flee, a repop):
    /// now when playing and not walking, else once we are. Skipped while our own run is in
    /// flight, which answers for the room as it is.
    mutating func refreshIfAuto() -> [ScriptEffect] {
        guard settings.auto != .off, !model.considering else { return [] }
        guard canRefresh else {
            pendingConsider = true
            return []
        }
        return autoConsider()
    }

    /// An automatic refresh: adopt a consider list someone else took in this
    /// room since ours, else send our own. Never the list already held: it
    /// predates the kills and departures marked on it since.
    mutating func autoConsider() -> [ScriptEffect] {
        if let occupants, let named = newConsiderList(occupants) {
            lastNamedAt = named.at
            model.adopt(named)
            statusNote = nil
            return [publishEffect()]
        }
        return beginConsiderSequence()
    }

    /// `conw on|area|off`, saying what is now in effect.
    mutating func setAutoMode(_ word: String) -> [ScriptEffect] {
        guard let mode = ConsiderAutoMode(rawValue: word) else { return [] }
        settings.auto = mode
        if mode == .off { pendingConsider = false }
        let note = switch mode {
        case .on: "Consider: auto-refresh on. The list refreshes as you move and as mobs come and go."
        case .area: "Consider: auto-refresh on until you leave \(currentZone ?? "this area")."
        case .off: "Consider: auto-refresh off. `conw` refreshes the list."
        }
        return [.echo(note)] + configChanged()
    }
}
