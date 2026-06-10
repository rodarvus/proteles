import Foundation

/// The mapper's persisted view preferences (per-profile, in `proteles_meta`):
/// the UI toggles and the scan depth. Each setter persists the new value and
/// republishes the layout so the map panel updates live. Split from
/// `Mapper.swift` for the file-length budget; the flags themselves (stored
/// properties) stay on the actor, `internal(set)` so these can write them.
public extension Mapper {
    /// Toggle whether other areas render inline, persist it, and republish.
    func setShowOtherAreas(_ value: Bool) {
        guard value != showOtherAreas else { return }
        showOtherAreas = value
        try? store.setMeta(value ? "1" : "0", forKey: Self.showOtherAreasKey)
        publishLayout()
    }

    /// Toggle the area-exit boundary markers, persist it, and republish.
    func setShowAreaExits(_ value: Bool) {
        guard value != showAreaExits else { return }
        showAreaExits = value
        try? store.setMeta(value ? "1" : "0", forKey: Self.showAreaExitsKey)
        publishLayout()
    }

    /// Toggle the PK warning animation, persist it, and republish.
    func setPKBlink(_ value: Bool) {
        guard value != pkBlink else { return }
        pkBlink = value
        try? store.setMeta(value ? "1" : "0", forKey: Self.pkBlinkKey)
        publishLayout()
    }

    /// Toggle whether room notes echo on arrival, and persist it.
    func setShowNotes(_ value: Bool) {
        guard value != showNotes else { return }
        showNotes = value
        try? store.setMeta(value ? "1" : "0", forKey: Self.showNotesKey)
    }

    /// Toggle the area background texture, persist it, and republish.
    func setUseTextures(_ value: Bool) {
        guard value != useTextures else { return }
        useTextures = value
        try? store.setMeta(value ? "1" : "0", forKey: Self.useTexturesKey)
        publishLayout()
    }

    /// Set how many rooms the map draws outward (clamped), persist, republish.
    func setScanDepth(_ value: Int) {
        let clamped = min(max(value, Self.scanDepthRange.lowerBound), Self.scanDepthRange.upperBound)
        guard clamped != scanDepth else { return }
        scanDepth = clamped
        try? store.setMeta(String(clamped), forKey: Self.scanDepthKey)
        publishLayout()
    }
}
