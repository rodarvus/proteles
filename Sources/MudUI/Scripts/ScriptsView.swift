import MudCore
import SwiftUI

/// The "Scripts" window: a tabbed master-detail editor for a world's
/// triggers, aliases, and timers (PLAN.md §8.6).
///
/// Each tab is a list + detail editor in the same shape as the Worlds
/// manager. Edits bind live through ``ScriptsModel`` so they persist and
/// take effect in the running session immediately.
public struct ScriptsView: View {
    @Bindable private var model: ScriptsModel

    public init(model: ScriptsModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            triggersTab
                .tabItem { Label("Triggers", systemImage: "bolt.fill") }
            aliasesTab
                .tabItem { Label("Aliases", systemImage: "text.cursor") }
            timersTab
                .tabItem { Label("Timers", systemImage: "timer") }
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Scripts")
    }

    // MARK: - Triggers

    private var triggersTab: some View {
        NavigationSplitView {
            List(selection: $model.selectedTriggerID) {
                ForEach(model.triggers) { trigger in
                    ScriptRow(
                        title: title(trigger.pattern.text, fallback: "New Trigger"),
                        subtitle: trigger.sendText ?? trigger.script ?? "—",
                        enabled: trigger.enabled
                    )
                    .tag(trigger.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                addRemoveToolbar(
                    add: { await model.addTrigger() },
                    remove: { await model.removeSelectedTrigger() },
                    canRemove: model.selectedTriggerID != nil
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
                        enabled: alias.enabled
                    )
                    .tag(alias.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                addRemoveToolbar(
                    add: { await model.addAlias() },
                    remove: { await model.removeSelectedAlias() },
                    canRemove: model.selectedAliasID != nil
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
                        enabled: timer.enabled
                    )
                    .tag(timer.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                addRemoveToolbar(
                    add: { await model.addTimer() },
                    remove: { await model.removeSelectedTimer() },
                    canRemove: model.selectedTimerID != nil
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

    // MARK: - Helpers

    private func title(_ text: String, fallback: String) -> String {
        text.isEmpty ? fallback : text
    }

    @ToolbarContentBuilder
    private func addRemoveToolbar(
        add: @escaping () async -> Void,
        remove: @escaping () async -> Void,
        canRemove: Bool
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { await add() } } label: { Label("Add", systemImage: "plus") }
            Button { Task { await remove() } } label: { Label("Remove", systemImage: "minus") }
                .disabled(!canRemove)
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

/// One row in a scripts list: title, a dimmed subtitle, and a dot that
/// fades when the item is disabled.
private struct ScriptRow: View {
    let title: String
    let subtitle: String
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(enabled ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
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
        .opacity(enabled ? 1 : 0.6)
    }
}
