import MudCore
import SwiftUI

/// The "Scripts" window: a tabbed master-detail editor for a world's
/// triggers, aliases, timers, and macros (PLAN.md §8.6).
///
/// Each tab is a list + detail editor in the same shape as the Worlds
/// manager. Edits bind live through ``ScriptsModel`` so they persist and
/// take effect in the running session immediately. List rows carry an
/// enable toggle + a Duplicate/Delete context menu; deletion confirms first.
public struct ScriptsView: View {
    @Bindable private var model: ScriptsModel
    @State private var deleteRequest: DeleteRequest?

    public init(model: ScriptsModel) {
        self.model = model
    }

    /// A pending deletion awaiting confirmation (carries the target's id).
    private enum DeleteRequest: Equatable {
        case trigger(UUID), alias(UUID), timer(UUID), macro(UUID)
    }

    public var body: some View {
        TabView {
            triggersTab
                .tabItem { Label("Triggers", systemImage: "bolt.fill") }
            aliasesTab
                .tabItem { Label("Aliases", systemImage: "text.cursor") }
            timersTab
                .tabItem { Label("Timers", systemImage: "timer") }
            macrosTab
                .tabItem { Label("Macros", systemImage: "keyboard") }
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Scripts")
        .confirmationDialog(
            "Delete this item?",
            isPresented: deletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) { deleteRequest = nil }
        } message: {
            Text("This removes it from the running session and can't be undone.")
        }
    }

    // MARK: - Triggers

    private var triggersTab: some View {
        NavigationSplitView {
            List(selection: $model.selectedTriggerID) {
                ForEach(model.triggers) { trigger in
                    ScriptRow(
                        title: title(trigger.pattern.text, fallback: "New Trigger"),
                        subtitle: trigger.sendText ?? trigger.script ?? "—",
                        isEnabled: model.binding(forTrigger: trigger.id)?.enabled
                            ?? .constant(trigger.enabled)
                    )
                    .tag(trigger.id)
                    .contextMenu {
                        rowMenu(
                            duplicate: { await model.duplicateTrigger(id: trigger.id) },
                            delete: { deleteRequest = .trigger(trigger.id) }
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    add: { await model.addTrigger() },
                    duplicate: { if let id = model.selectedTriggerID { await model.duplicateTrigger(id: id) }
                    },
                    requestDelete: { if let id = model.selectedTriggerID { deleteRequest = .trigger(id) } },
                    canModify: model.selectedTriggerID != nil
                )
            }
        } detail: {
            if let id = model.selectedTriggerID, let binding = model.binding(forTrigger: id) {
                TriggerEditorView(trigger: binding)
            } else {
                unavailable("No Trigger Selected", systemImage: "bolt")
            }
        }
    }

    // MARK: - Aliases

    private var aliasesTab: some View {
        NavigationSplitView {
            List(selection: $model.selectedAliasID) {
                ForEach(model.aliases) { alias in
                    ScriptRow(
                        title: title(alias.pattern.text, fallback: "New Alias"),
                        subtitle: alias.sendText ?? "—",
                        isEnabled: model.binding(forAlias: alias.id)?.enabled
                            ?? .constant(alias.enabled)
                    )
                    .tag(alias.id)
                    .contextMenu {
                        rowMenu(
                            duplicate: { await model.duplicateAlias(id: alias.id) },
                            delete: { deleteRequest = .alias(alias.id) }
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    add: { await model.addAlias() },
                    duplicate: { if let id = model.selectedAliasID { await model.duplicateAlias(id: id) } },
                    requestDelete: { if let id = model.selectedAliasID { deleteRequest = .alias(id) } },
                    canModify: model.selectedAliasID != nil
                )
            }
        } detail: {
            if let id = model.selectedAliasID, let binding = model.binding(forAlias: id) {
                AliasEditorView(alias: binding)
            } else {
                unavailable("No Alias Selected", systemImage: "text.cursor")
            }
        }
    }

    // MARK: - Timers

    private var timersTab: some View {
        NavigationSplitView {
            List(selection: $model.selectedTimerID) {
                ForEach(model.timers) { timer in
                    ScriptRow(
                        title: timer.label?.isEmpty == false ? timer.label! : "Timer",
                        subtitle: Self.timerSummary(timer),
                        isEnabled: model.binding(forTimer: timer.id)?.enabled
                            ?? .constant(timer.enabled)
                    )
                    .tag(timer.id)
                    .contextMenu {
                        rowMenu(
                            duplicate: { await model.duplicateTimer(id: timer.id) },
                            delete: { deleteRequest = .timer(timer.id) }
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    add: { await model.addTimer() },
                    duplicate: { if let id = model.selectedTimerID { await model.duplicateTimer(id: id) } },
                    requestDelete: { if let id = model.selectedTimerID { deleteRequest = .timer(id) } },
                    canModify: model.selectedTimerID != nil
                )
            }
        } detail: {
            if let id = model.selectedTimerID, let binding = model.binding(forTimer: id) {
                TimerEditorView(timer: binding)
            } else {
                unavailable("No Timer Selected", systemImage: "timer")
            }
        }
    }

    // MARK: - Macros

    private var macrosTab: some View {
        NavigationSplitView {
            List(selection: $model.selectedMacroID) {
                ForEach(model.macros) { macro in
                    ScriptRow(
                        title: macroTitle(macro),
                        subtitle: macro.action.text.isEmpty ? "—" : macro.action.text,
                        isEnabled: model.binding(forMacro: macro.id)?.enabled
                            ?? .constant(macro.enabled)
                    )
                    .tag(macro.id)
                    .contextMenu {
                        rowMenu(
                            duplicate: { await model.duplicateMacro(id: macro.id) },
                            delete: { deleteRequest = .macro(macro.id) }
                        )
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                itemToolbar(
                    add: { await model.addMacro() },
                    duplicate: { if let id = model.selectedMacroID { await model.duplicateMacro(id: id) } },
                    requestDelete: { if let id = model.selectedMacroID { deleteRequest = .macro(id) } },
                    canModify: model.selectedMacroID != nil
                )
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Restore Default Keypad Layout") {
                            Task { await model.restoreDefaultMacros() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        } detail: {
            if let id = model.selectedMacroID, let binding = model.binding(forMacro: id) {
                MacroEditorView(macro: binding)
            } else {
                unavailable("No Macro Selected", systemImage: "keyboard")
            }
        }
    }

    private func macroTitle(_ macro: Macro) -> String {
        if let name = macro.name, !name.isEmpty { return name }
        return KeyChordFormatter.describe(macro.chord)
    }

    // MARK: - Helpers

    private func title(_ text: String, fallback: String) -> String {
        text.isEmpty ? fallback : text
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } })
    }

    private func performDelete() async {
        switch deleteRequest {
        case .trigger(let id):
            model.selectedTriggerID = id
            await model.removeSelectedTrigger()
        case .alias(let id):
            model.selectedAliasID = id
            await model.removeSelectedAlias()
        case .timer(let id):
            model.selectedTimerID = id
            await model.removeSelectedTimer()
        case .macro(let id):
            model.selectedMacroID = id
            await model.removeSelectedMacro()
        case nil:
            break
        }
        deleteRequest = nil
    }

    @ViewBuilder
    private func rowMenu(
        duplicate: @escaping () async -> Void,
        delete: @escaping () -> Void
    ) -> some View {
        Button("Duplicate") { Task { await duplicate() } }
        Button("Delete", role: .destructive, action: delete)
    }

    @ToolbarContentBuilder
    private func itemToolbar(
        add: @escaping () async -> Void,
        duplicate: @escaping () async -> Void,
        requestDelete: @escaping () -> Void,
        canModify: Bool
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await add() } } label: { Label("Add", systemImage: "plus") }
            Button { Task { await duplicate() } } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .disabled(!canModify)
            Button(role: .destructive, action: requestDelete) {
                Label("Remove", systemImage: "minus")
            }
            .disabled(!canModify)
        }
    }

    private func unavailable(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("Select an item from the list, or add a new one.")
        )
    }

    private static func timerSummary(_ timer: MudTimer) -> String {
        switch timer.schedule {
        case .after(let delay): "once after \(Self.seconds(delay))"
        case .every(let interval, _): "every \(Self.seconds(interval))"
        case .atTimeOfDay(let hour, let minute, _):
            String(format: "daily at %02d:%02d", hour, minute)
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        value == value.rounded() ? "\(Int(value))s" : "\(value)s"
    }
}

/// One row in a scripts list: an enable checkbox, a title, and a dimmed
/// subtitle. The row dims when disabled.
private struct ScriptRow: View {
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            enableToggle
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .opacity(isEnabled ? 1 : 0.6)
    }

    private var enableToggle: some View {
        Toggle("Enabled", isOn: $isEnabled)
            .labelsHidden()
            .help("Enable or disable this item")
        #if os(macOS)
            .toggleStyle(.checkbox)
        #endif
    }
}
