import Observation
import SwiftUI

/// Menu hooks for importing / resetting the **plugin-owned** SQLite databases
/// (dinv inventory, leveldb leveling history). A thin closure-carrier — the app
/// wires the actual file-picker + ``MudCore/PluginDatabaseImporter`` work (it
/// owns the macOS UI + the session/character context), exactly like
/// ``SnDPanelModel``'s import/reset hooks. Unlike the mapper/S&D merges these
/// are whole-file *replaces* (plugin-owned schemas can't be safely merged), so
/// they're done while disconnected and take effect on the next connect.
@MainActor
@Observable
public final class PluginDatabasesModel {
    @ObservationIgnored public var onImportDinv: (@MainActor () -> Void)?
    @ObservationIgnored public var onResetDinv: (@MainActor () -> Void)?
    @ObservationIgnored public var onImportLevelDB: (@MainActor () -> Void)?
    @ObservationIgnored public var onResetLevelDB: (@MainActor () -> Void)?

    public init() {}

    public func importDinv() {
        onImportDinv?()
    }

    public func resetDinv() {
        onResetDinv?()
    }

    public func importLevelDB() {
        onImportLevelDB?()
    }

    public func resetLevelDB() {
        onResetLevelDB?()
    }
}
