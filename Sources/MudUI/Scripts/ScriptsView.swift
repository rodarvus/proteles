import MudCore
import SwiftUI

/// The "Scripts" window: a tabbed master-detail editor for a world's
/// triggers, aliases, timers, and macros (PLAN.md §8.6).
///
/// Each tab is a list + detail editor in the same shape as the Worlds
/// manager. Edits bind live through ``ScriptsModel`` so they persist and
/// take effect in the running session immediately. List rows carry an
/// enable toggle + a Duplicate/Delete context menu, mirrored by the toolbar.
///
/// Polish pass (#35): every list is filterable (the toolbar search field),
/// Add/Duplicate ride ⌘N/⌘D and the Delete key deletes (keyboard-first,
/// DESIGN.md §3.2), deletes confirm (§3.7), empty lists explain themselves
/// (§3.5), and grouped items get per-group bulk enable/disable.
///
/// The five tab builders live in `ScriptsView+Tabs.swift`; this file holds
/// the window shell + the shared delete-confirmation plumbing. The stored
/// properties are `internal` (not `private`) so that extension file can
/// reach them — stored state can't move into an extension.
public struct ScriptsView: View {
    /// Which tab is frontmost — drives the ⌘N/⌘D routing (the shortcut
    /// belongs to the visible tab's toolbar only, so the chord is unambiguous).
    enum Tab: Hashable {
        case triggers, aliases, timers, macros, buttons
    }

    @Bindable var model: ScriptsModel
    @State var selectedTab: Tab = .triggers
    @State var triggerQuery = ""
    @State var aliasQuery = ""
    @State var timerQuery = ""
    @State var macroQuery = ""
    @State var deleteRequest: ScriptsDeleteRequest?

    public init(model: ScriptsModel) {
        self.model = model
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            triggersTab
                .tabItem { Label("Triggers", systemImage: "bolt.fill") }
                .tag(Tab.triggers)
            aliasesTab
                .tabItem { Label("Aliases", systemImage: "text.cursor") }
                .tag(Tab.aliases)
            timersTab
                .tabItem { Label("Timers", systemImage: "timer") }
                .tag(Tab.timers)
            macrosTab
                .tabItem { Label("Macros", systemImage: "keyboard") }
                .tag(Tab.macros)
            buttonsTab
                .tabItem { Label("Buttons", systemImage: "rectangle.grid.2x2") }
                .tag(Tab.buttons)
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Scripts")
        .confirmationDialog(
            deleteRequest?.title ?? "",
            isPresented: confirmingDelete,
            titleVisibility: .visible,
            presenting: deleteRequest
        ) { request in
            Button(request.confirmLabel, role: .destructive) {
                Task { await perform(request) }
            }
        } message: { request in
            Text(request.message)
        }
    }

    // MARK: - Delete confirmation

    private var confirmingDelete: Binding<Bool> {
        Binding(
            get: { deleteRequest != nil },
            set: { if !$0 { deleteRequest = nil } }
        )
    }

    private func perform(_ request: ScriptsDeleteRequest) async {
        switch request.action {
        case .deleteTrigger(let id):
            model.selectedTriggerID = id
            await model.removeSelectedTrigger()
        case .deleteAlias(let id):
            model.selectedAliasID = id
            await model.removeSelectedAlias()
        case .deleteTimer(let id):
            model.selectedTimerID = id
            await model.removeSelectedTimer()
        case .deleteMacro(let id):
            model.selectedMacroID = id
            await model.removeSelectedMacro()
        case .deleteButton(let id):
            await model.deleteButton(id)
        case .deleteButtonGroup(let id):
            await model.deleteButtonGroup(id)
        case .restoreDefaultMacros:
            await model.restoreDefaultMacros()
        }
    }
}
