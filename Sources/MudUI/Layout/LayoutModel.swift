import Observation
import SwiftUI

/// Drives the main window's docked panel area (PLAN.md §8.5). Auxiliary
/// "miniwindow" panels (Info, Map, Chat, …) live in a single resizable
/// right-hand dock — never separate OS windows that could fall behind the
/// game window. One panel shows at a time, selected by a segmented control
/// or the menu commands.
///
/// This is the minimal first step toward a configurable, Geyser-like layout;
/// for now it's one tabbed right dock so the vertical MUD output keeps its
/// width.
@MainActor
@Observable
public final class LayoutModel {
    /// A dockable live panel.
    public enum Panel: String, CaseIterable, Identifiable, Sendable {
        case info, map, chat

        public var id: String {
            rawValue
        }

        public var title: String {
            switch self {
            case .info: "Info"
            case .map: "Map"
            case .chat: "Chat"
            }
        }

        public var systemImage: String {
            switch self {
            case .info: "info.circle"
            case .map: "map"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
    }

    /// Whether the right dock is shown.
    public var dockVisible: Bool
    /// The panel currently displayed in the dock.
    public var selectedPanel: Panel

    public init(dockVisible: Bool = true, selectedPanel: Panel = .info) {
        self.dockVisible = dockVisible
        self.selectedPanel = selectedPanel
    }

    /// Reveal the dock and switch to `panel` (used by the menu commands).
    public func show(_ panel: Panel) {
        selectedPanel = panel
        dockVisible = true
    }

    public func toggleDock() {
        dockVisible.toggle()
    }
}
