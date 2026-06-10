import Foundation

/// Phase 7 of the mapper-fidelity work: the display-window and multi-database
/// commands. Per the project decision (D-/PLAN §mapper-fidelity), Proteles has a
/// *native* map panel and a single global database model — it does NOT reproduce
/// MUSHclient's miniwindow or multi-DB behaviour. So these commands keep working
/// (no "unknown command" errors) but route to the native panel / Databases menu
/// with a short note saying where the feature lives. The genuinely native
/// toggles we *do* own — `shownotes`, `depth`, `blink`, `textures` — stay real.
extension Mapper {
    /// Display-window commands (`zoom`/`hide`/`show`/`showroom`/`updown`/
    /// `underlines`/`compact`/`quicklist`, plus the native `textures` toggle)
    /// → the native map panel. Returns `nil` for anything it doesn't own.
    func handleDisplayCommand(_ sub: String, _ arg: String) -> [ScriptEffect]? {
        switch sub {
        case "textures":
            texturesCommand(arg)
        case "zoom":
            [Self.note("Map zoom is a native control — use the map panel's zoom (⌘+ / ⌘-).")]
        case "hide", "show":
            [Self.note("Show or hide the map from the native map panel.")]
        case "showroom":
            [Self.note("Centre a room from the native map panel.")]
        case "updown":
            [Self.note("Up/down exit rendering is handled by the native map panel.")]
        case "underlines":
            [Self.note("Mapper hyperlink styling follows Proteles's native theme.")]
        case "compact":
            [Self.note("Proteles already renders mapper output compactly; no toggle needed.")]
        case "quicklist":
            [Self.note("Search results render natively; there's no separate quicklist mode.")]
        default:
            nil
        }
    }

    /// `mapper textures [on|off]` — toggle the tiled per-area background
    /// texture (the reference's "Area Textures" config). Image files come
    /// from `~/Documents/Proteles/MapImages/`; none ship with Proteles (#11).
    private func texturesCommand(_ arg: String) -> [ScriptEffect] {
        switch arg.lowercased() {
        case "on": setUseTextures(true); return [Self.note("Area textures: on.")]
        case "off": setUseTextures(false); return [Self.note("Area textures: off.")]
        case "": return [Self.note(
                "Area textures are \(useTextures ? "on" : "off") "
                    + "(images in ~/Documents/Proteles/MapImages). Use 'mapper textures on|off'."
            )]
        default: return [Self.note("Usage: mapper textures on|off")]
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
