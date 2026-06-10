import MudCore
import SwiftUI

/// The Scripts window's five tabs (split out of `ScriptsView.swift` for the
/// file/type budget). Each tab is the same shape: a filterable list column
/// (with an explain-yourself empty state) + a form detail editor, an
/// Add/Duplicate/Delete toolbar on ⌘N/⌘D/⌫, and confirm-before-delete
/// routed through ``ScriptsDeleteRequest``.
extension ScriptsView {
    /// A toolbar switch toggling whether this kind is shared across all
    /// characters (stored in `Scripts/_shared`) or kept per-character.
    @ToolbarContentBuilder
    private func scopeToggleItem(_ kind: ScriptScope.Kind) -> some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Toggle("Shared", isOn: Binding(
                get: { model.scriptScope.isGlobal(kind) },
                set: { on in Task { await model.setScriptGlobal(kind, on) } }
            ))
            .toggleStyle(.switch)
            .help("Share these \(kind.rawValue) across all your characters "
                + "(Scripts/_shared) instead of keeping them per-character.")
        }
    }

    // MARK: - Triggers

    private var filteredTriggers: [Trigger] {
        model.triggers.filter { ScriptItemFilter.matches($0, query: triggerQuery) }
    }

    var triggersTab: some View {
        NavigationSplitView {
            Group {
                if model.triggers.isEmpty {
                    emptyList(
                        "No Triggers",
                        systemImage: "bolt",
                        blurb: "A trigger watches the game's output and reacts "
                            + "— send a command, run a script, or hide the line.",
                        addLabel: "Add Trigger",
                        add: { await model.addTrigger() }
                    )
                } else if filteredTriggers.isEmpty {
                    ContentUnavailableView.search(text: triggerQuery)
                } else {
                    triggersList
                }
            }
            .searchable(text: $triggerQuery, placement: .sidebar, prompt: "Filter")
            .searchFocused($filterFocus, equals: .triggers)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    isActive: selectedTab == .triggers,
                    add: { triggerQuery = ""; await model.addTrigger() },
                    duplicate: {
                        if let id = model.selectedTriggerID { await model.duplicateTrigger(id: id) }
                    },
                    remove: { confirmDeleteSelectedTrigger() },
                    canModify: model.selectedTriggerID != nil
                )
                scopeToggleItem(.triggers)
            }
        } detail: {
            if let id = model.selectedTriggerID, let binding = model.binding(forTrigger: id) {
                TriggerEditorView(trigger: binding)
            } else {
                unavailable("No Trigger Selected", systemImage: "bolt")
            }
        }
    }

    private var triggersList: some View {
        List(selection: $model.selectedTriggerID) {
            ForEach(filteredTriggers) { trigger in
                ScriptRow(
                    title: Self.title(trigger.pattern.text, fallback: "New Trigger"),
                    subtitle: trigger.sendText ?? trigger.script ?? "—",
                    badge: trigger.group,
                    isEnabled: model.binding(forTrigger: trigger.id)?.enabled
                        ?? .constant(trigger.enabled)
                )
                .tag(trigger.id)
                .contextMenu {
                    rowMenu(
                        duplicate: { await model.duplicateTrigger(id: trigger.id) },
                        delete: { deleteRequest = .trigger(trigger) }
                    )
                    groupMenu(trigger.group) { group, enabled in
                        await model.setTriggerGroupEnabled(group, enabled)
                    }
                }
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedTrigger() }
    }

    private func confirmDeleteSelectedTrigger() {
        guard let trigger = model.triggers.first(where: { $0.id == model.selectedTriggerID })
        else { return }
        deleteRequest = .trigger(trigger)
    }

    // MARK: - Aliases

    private var filteredAliases: [Alias] {
        model.aliases.filter { ScriptItemFilter.matches($0, query: aliasQuery) }
    }

    var aliasesTab: some View {
        NavigationSplitView {
            Group {
                if model.aliases.isEmpty {
                    emptyList(
                        "No Aliases",
                        systemImage: "text.cursor",
                        blurb: "An alias expands a short command you type into "
                            + "something longer before it's sent.",
                        addLabel: "Add Alias",
                        add: { await model.addAlias() }
                    )
                } else if filteredAliases.isEmpty {
                    ContentUnavailableView.search(text: aliasQuery)
                } else {
                    aliasesList
                }
            }
            .searchable(text: $aliasQuery, placement: .sidebar, prompt: "Filter")
            .searchFocused($filterFocus, equals: .aliases)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    isActive: selectedTab == .aliases,
                    add: { aliasQuery = ""; await model.addAlias() },
                    duplicate: {
                        if let id = model.selectedAliasID { await model.duplicateAlias(id: id) }
                    },
                    remove: { confirmDeleteSelectedAlias() },
                    canModify: model.selectedAliasID != nil
                )
                scopeToggleItem(.aliases)
            }
        } detail: {
            if let id = model.selectedAliasID, let binding = model.binding(forAlias: id) {
                AliasEditorView(alias: binding)
            } else {
                unavailable("No Alias Selected", systemImage: "text.cursor")
            }
        }
    }

    private var aliasesList: some View {
        List(selection: $model.selectedAliasID) {
            ForEach(filteredAliases) { alias in
                ScriptRow(
                    title: Self.title(alias.pattern.text, fallback: "New Alias"),
                    subtitle: alias.sendText ?? "—",
                    badge: alias.group,
                    isEnabled: model.binding(forAlias: alias.id)?.enabled
                        ?? .constant(alias.enabled)
                )
                .tag(alias.id)
                .contextMenu {
                    rowMenu(
                        duplicate: { await model.duplicateAlias(id: alias.id) },
                        delete: { deleteRequest = .alias(alias) }
                    )
                    groupMenu(alias.group) { group, enabled in
                        await model.setAliasGroupEnabled(group, enabled)
                    }
                }
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedAlias() }
    }

    private func confirmDeleteSelectedAlias() {
        guard let alias = model.aliases.first(where: { $0.id == model.selectedAliasID })
        else { return }
        deleteRequest = .alias(alias)
    }

    // MARK: - Timers

    private var filteredTimers: [MudTimer] {
        model.timers.filter { ScriptItemFilter.matches($0, query: timerQuery) }
    }

    var timersTab: some View {
        NavigationSplitView {
            Group {
                if model.timers.isEmpty {
                    emptyList(
                        "No Timers",
                        systemImage: "timer",
                        blurb: "A timer sends a command or runs a script on a "
                            + "schedule — once, repeating, or daily.",
                        addLabel: "Add Timer",
                        add: { await model.addTimer() }
                    )
                } else if filteredTimers.isEmpty {
                    ContentUnavailableView.search(text: timerQuery)
                } else {
                    timersList
                }
            }
            .searchable(text: $timerQuery, placement: .sidebar, prompt: "Filter")
            .searchFocused($filterFocus, equals: .timers)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    isActive: selectedTab == .timers,
                    add: { timerQuery = ""; await model.addTimer() },
                    duplicate: {
                        if let id = model.selectedTimerID { await model.duplicateTimer(id: id) }
                    },
                    remove: { confirmDeleteSelectedTimer() },
                    canModify: model.selectedTimerID != nil
                )
                scopeToggleItem(.timers)
            }
        } detail: {
            if let id = model.selectedTimerID, let binding = model.binding(forTimer: id) {
                TimerEditorView(timer: binding)
            } else {
                unavailable("No Timer Selected", systemImage: "timer")
            }
        }
    }

    private var timersList: some View {
        List(selection: $model.selectedTimerID) {
            ForEach(filteredTimers) { timer in
                ScriptRow(
                    title: timer.label?.isEmpty == false ? timer.label! : "Timer",
                    subtitle: Self.timerSummary(timer),
                    badge: timer.group,
                    isEnabled: model.binding(forTimer: timer.id)?.enabled
                        ?? .constant(timer.enabled)
                )
                .tag(timer.id)
                .contextMenu {
                    rowMenu(
                        duplicate: { await model.duplicateTimer(id: timer.id) },
                        delete: { deleteRequest = .timer(timer) }
                    )
                    groupMenu(timer.group) { group, enabled in
                        await model.setTimerGroupEnabled(group, enabled)
                    }
                }
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedTimer() }
    }

    private func confirmDeleteSelectedTimer() {
        guard let timer = model.timers.first(where: { $0.id == model.selectedTimerID })
        else { return }
        deleteRequest = .timer(timer)
    }

    // MARK: - Macros

    private var filteredMacros: [Macro] {
        model.macros.filter { ScriptItemFilter.matches($0, query: macroQuery) }
    }

    var macrosTab: some View {
        NavigationSplitView {
            Group {
                if model.macros.isEmpty {
                    emptyList(
                        "No Macros",
                        systemImage: "keyboard",
                        blurb: "A macro binds a key (or key combination) to a "
                            + "command or script.",
                        addLabel: "Add Macro",
                        add: { await model.addMacro() }
                    )
                } else if filteredMacros.isEmpty {
                    ContentUnavailableView.search(text: macroQuery)
                } else {
                    macrosList
                }
            }
            .searchable(text: $macroQuery, placement: .sidebar, prompt: "Filter")
            .searchFocused($filterFocus, equals: .macros)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    isActive: selectedTab == .macros,
                    add: { macroQuery = ""; await model.addMacro() },
                    duplicate: {
                        if let id = model.selectedMacroID { await model.duplicateMacro(id: id) }
                    },
                    remove: { confirmDeleteSelectedMacro() },
                    canModify: model.selectedMacroID != nil
                )
                scopeToggleItem(.macros)
            }
        } detail: {
            if let id = model.selectedMacroID, let binding = model.binding(forMacro: id) {
                MacroEditorView(macro: binding)
            } else {
                unavailable("No Macro Selected", systemImage: "keyboard")
            }
        }
    }

    private var macrosList: some View {
        List(selection: $model.selectedMacroID) {
            ForEach(filteredMacros) { macro in
                ScriptRow(
                    title: Self.macroTitle(macro),
                    subtitle: macro.action.text.isEmpty ? "—" : macro.action.text,
                    isEnabled: model.binding(forMacro: macro.id)?.enabled
                        ?? .constant(macro.enabled)
                )
                .tag(macro.id)
                .contextMenu {
                    rowMenu(
                        duplicate: { await model.duplicateMacro(id: macro.id) },
                        delete: { deleteRequest = .macro(macro) }
                    )
                }
            }
        }
        .onDeleteCommandCompat { confirmDeleteSelectedMacro() }
    }

    private func confirmDeleteSelectedMacro() {
        guard let macro = model.macros.first(where: { $0.id == model.selectedMacroID })
        else { return }
        deleteRequest = .macro(macro)
    }

    // MARK: - Keypad (D-102)

    var keypadTab: some View {
        KeypadEditorView(model: model)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        deleteRequest = .restoreDefaultKeypad
                    } label: {
                        Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .help("Replace all keypad commands with the built-in navigation set")
                }
            }
    }

    // The Buttons tab lives in ScriptsView+ButtonsTab.swift (D-106).

    // MARK: - Shared menus + toolbar

    @ViewBuilder
    private func rowMenu(
        duplicate: @escaping () async -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        Button("Duplicate") { Task { await duplicate() } }
        Button("Delete", role: .destructive) { delete() }
    }

    /// Bulk enable/disable for the row's group, when it has one.
    @ViewBuilder
    private func groupMenu(
        _ group: String?,
        setEnabled: @escaping (String, Bool) async -> Void
    ) -> some View {
        if let group, !group.isEmpty {
            Divider()
            Button("Enable All in “\(group)”") {
                Task { await setEnabled(group, true) }
            }
            Button("Disable All in “\(group)”") {
                Task { await setEnabled(group, false) }
            }
        }
    }

    /// The Add/Duplicate/Delete toolbar trio. ⌘N/⌘D attach only while
    /// `isActive` (the tab is frontmost), so each chord has exactly one
    /// owner; the Delete *key* routes through each list's `onDeleteCommand`
    /// instead, so it never swallows Delete while typing in the editor.
    @ToolbarContentBuilder
    private func itemToolbar(
        isActive: Bool,
        add: @escaping () async -> Void,
        duplicate: @escaping () async -> Void,
        remove: @escaping () -> Void,
        canModify: Bool
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await add() } } label: { Label("Add", systemImage: "plus") }
                .help("Add (⌘N)")
                .keyboardShortcut(isActive ? KeyboardShortcut("n", modifiers: .command) : nil)
            Button { Task { await duplicate() } } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .help("Duplicate (⌘D)")
            .keyboardShortcut(isActive ? KeyboardShortcut("d", modifiers: .command) : nil)
            .disabled(!canModify)
            Button(role: .destructive) { remove() } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete (⌫ in the list)")
            .disabled(!canModify)
        }
    }
}
