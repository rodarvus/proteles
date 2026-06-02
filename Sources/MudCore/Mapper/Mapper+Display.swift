import Foundation

/// Phase 7 of the mapper-fidelity work: the display-window and multi-database
/// commands. Per the project decision (D-/PLAN §mapper-fidelity), Proteles has a
/// *native* map panel and a single global database model — it does NOT reproduce
/// MUSHclient's miniwindow or multi-DB behaviour. So these commands keep working
/// (no "unknown command" errors) but route to the native panel / Databases menu
/// with a short note saying where the feature lives. The genuinely native
/// toggles we *do* own — `shownotes`, `depth`, `blink` — stay real elsewhere.
extension Mapper {
    /// Display-window commands (`zoom`/`hide`/`show`/`showroom`/`updown`/
    /// `underlines`/`compact`/`quicklist`) → the native map panel. Returns `nil`
    /// for anything it doesn't own.
    func handleDisplayCommand(_ sub: String, _ arg: String) -> [ScriptEffect]? {
        _ = arg
        switch sub {
        case "zoom":
            return [Self.note("Map zoom is a native control — use the map panel's zoom (⌘+ / ⌘-).")]
        case "hide", "show":
            return [Self.note("Show or hide the map from the native map panel.")]
        case "showroom":
            return [Self.note("Centre a room from the native map panel.")]
        case "updown":
            return [Self.note("Up/down exit rendering is handled by the native map panel.")]
        case "underlines":
            return [Self.note("Mapper hyperlink styling follows Proteles's native theme.")]
        case "compact":
            return [Self.note("Proteles already renders mapper output compactly; no toggle needed.")]
        case "quicklist":
            return [Self.note("Search results render natively; there's no separate quicklist mode.")]
        default:
            return nil
        }
    }

    /// Multi-database commands (`database` / `set database` / `backups`) → the
    /// native global database model + Databases menu. Returns `nil` otherwise.
    func handleDatabaseCommand(_ sub: String, _ arg: String) -> [ScriptEffect]? {
        switch sub {
        case "database":
            // Faithful + real: report the active database file (reference
            // "Current mapper database file is <name>.db").
            [Self.note("Current mapper database file is \(store.url.lastPathComponent)")]
        case "set" where arg.split(separator: " ").first?.lowercased() == "database":
            [Self.note("Switch the mapper database from Proteles's Databases menu.")]
        case "backups":
            [Self.note("Map backups are managed from Proteles's Databases menu.")]
        default:
            nil
        }
    }
}
