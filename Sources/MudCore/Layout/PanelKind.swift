import Foundation

/// The set of dockable panels the layout can arrange (PLAN.md §8.5 / the UI
/// revamp, `docs/UI_REVAMP.md`). A `PanelKind` is a stable identifier only —
/// the actual SwiftUI view for each kind is supplied by the app at render time,
/// so this data model stays UI-agnostic, `Codable`, and unit-testable.
///
/// `output` (the main MUD text + its full-width gauges) is itself a panel so it
/// resizes/arranges like any other; it is the one panel that can't be closed.
public enum PanelKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The main MUD output column (text + command input + full-width vitals).
    case output
    /// The native graphical map (Mapper / GMCP).
    case map
    /// The ASCII "text map" Aardwolf draws (captured by the AsciiMap plugin).
    case asciiMap
    /// Captured chat / comm channels.
    case channels
    /// Search-and-Destroy targets/navigation.
    case hunt
    /// Character summary (level/class/align/worth) + group/party members.
    case info
    /// In-game help reader (captured `help <topic>` with clickable cross-refs).
    case help
    /// Native leveldb reporting (live HUD / tables / analytics / journey).
    case levels
    /// Configurable command-button bar (#15).
    case commandBar

    public var id: String {
        rawValue
    }

    /// Human-readable panel title (tab labels, Panels menu, window chrome).
    public var title: String {
        switch self {
        case .output: "Game"
        case .map: "Map"
        case .asciiMap: "Text Map"
        case .channels: "Channels"
        case .hunt: "Search & Destroy"
        case .info: "Character"
        case .help: "Help"
        case .levels: "Levels"
        case .commandBar: "Commands"
        }
    }

    /// A shorter label for tight spots (tab strips).
    public var shortTitle: String {
        switch self {
        case .output: "Game"
        case .map: "Map"
        case .asciiMap: "Text"
        case .channels: "Chat"
        case .hunt: "S&D"
        case .info: "Char"
        case .help: "Help"
        case .levels: "Levels"
        case .commandBar: "Cmds"
        }
    }

    /// SF Symbol shown in menus / tab strips.
    public var systemImage: String {
        switch self {
        case .output: "terminal"
        case .map: "map"
        case .asciiMap: "square.grid.3x3"
        case .channels: "bubble.left.and.bubble.right"
        case .hunt: "scope"
        case .info: "person.text.rectangle"
        case .help: "questionmark.circle"
        case .levels: "chart.line.uptrend.xyaxis"
        case .commandBar: "rectangle.grid.2x2"
        }
    }

    /// The main output is permanent; every other panel can be hidden.
    public var isClosable: Bool {
        self != .output
    }

    /// As a floating miniwindow (GH #33), does this panel have a compact
    /// intrinsic size to hug (Text Map, Commands), or is it a fill-style panel
    /// (Channels, Map, S&D, Character) that needs an explicit initial size so it
    /// doesn't collapse to nothing?
    public var floatingHugsContent: Bool {
        switch self {
        case .asciiMap, .commandBar, .info: true
        default: false
        }
    }

    /// Panels a user can toggle from the Panels menu (everything but `output`).
    /// `help` and `levels` are excluded — they're dedicated windows now, not dock
    /// tiles (the cases remain so older saved layouts that docked them still
    /// decode/render).
    public static var toggleable: [PanelKind] {
        allCases.filter { $0.isClosable && $0 != .help && $0 != .levels }
    }
}
