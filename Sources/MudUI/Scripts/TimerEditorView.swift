import MudCore
import SwiftUI

/// The selectable kinds of ``TimerSchedule``.
private enum ScheduleKind: String, CaseIterable, Identifiable {
    case after, every, atTimeOfDay
    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .after: "Once, after a delay"
        case .every: "Every interval"
        case .atTimeOfDay: "Daily at a time"
        }
    }
}

private extension TimerSchedule {
    var kind: ScheduleKind {
        switch self {
        case .after: .after
        case .every: .every
        case .atTimeOfDay: .atTimeOfDay
        }
    }
}

/// Detail editor for one ``MudTimer``. Binds live through
/// ``ScriptsModel/binding(forTimer:)``.
struct TimerEditorView: View {
    @Binding var timer: MudTimer

    var body: some View {
        Form {
            Section("Schedule") {
                Picker("When", selection: scheduleKind) {
                    ForEach(ScheduleKind.allCases) { Text($0.label).tag($0) }
                }
                scheduleFields
            }

            Section("Action") {
                Picker("Do", selection: actionIsScript) {
                    Text("Send to MUD").tag(false)
                    Text("Run Lua script").tag(true)
                }
                TextField(
                    actionIsScript.wrappedValue ? "Script (Lua)" : "Send",
                    text: actionText,
                    axis: .vertical
                )
                .font(.body.monospaced())
                .lineLimit(1...8)
            }

            Section("Options") {
                Toggle("Enabled", isOn: $timer.enabled)
                TextField("Label", text: $timer.label.orEmpty())
                TextField("Group", text: $timer.group.orEmpty())
            }
        }
        .formStyle(.grouped)
        .navigationTitle(timer.label?.isEmpty == false ? timer.label! : "Timer")
    }

    @ViewBuilder
    private var scheduleFields: some View {
        switch timer.schedule {
        case .after:
            TextField("Delay (seconds)", value: afterDelay, format: .number)
        case .every:
            TextField("Interval (seconds)", value: everyInterval, format: .number)
            TextField("First-fire offset (seconds)", value: everyOffset, format: .number)
        case .atTimeOfDay:
            TextField("Hour (0–23)", value: atHour, format: .number.grouping(.never))
            TextField("Minute (0–59)", value: atMinute, format: .number.grouping(.never))
            TextField("Second", value: atSecond, format: .number)
        }
    }

    // MARK: - Schedule bindings

    private var scheduleKind: Binding<ScheduleKind> {
        Binding(
            get: { timer.schedule.kind },
            set: { kind in
                switch kind {
                case .after: timer.schedule = .after(5)
                case .every: timer.schedule = .every(60)
                case .atTimeOfDay: timer.schedule = .atTimeOfDay(hour: 9, minute: 0)
                }
            }
        )
    }

    private var afterDelay: Binding<Double> {
        Binding(
            get: { if case .after(let value) = timer.schedule { value } else { 0 } },
            set: { timer.schedule = .after($0) }
        )
    }

    private var everyInterval: Binding<Double> {
        Binding(
            get: { if case .every(let value, _) = timer.schedule { value } else { 0 } },
            set: {
                let offset = if case .every(_, let off) = timer.schedule { off } else { 0.0 }
                timer.schedule = .every($0, offset: offset)
            }
        )
    }

    private var everyOffset: Binding<Double> {
        Binding(
            get: { if case .every(_, let value) = timer.schedule { value } else { 0 } },
            set: {
                let interval = if case .every(let value, _) = timer.schedule { value } else { 60.0 }
                timer.schedule = .every(interval, offset: $0)
            }
        )
    }

    private var atHour: Binding<Int> {
        Binding(
            get: { if case .atTimeOfDay(let hour, _, _) = timer.schedule { hour } else { 0 } },
            set: {
                guard case .atTimeOfDay(_, let minute, let second) = timer.schedule else { return }
                timer.schedule = .atTimeOfDay(hour: $0, minute: minute, second: second)
            }
        )
    }

    private var atMinute: Binding<Int> {
        Binding(
            get: { if case .atTimeOfDay(_, let minute, _) = timer.schedule { minute } else { 0 } },
            set: {
                guard case .atTimeOfDay(let hour, _, let second) = timer.schedule else { return }
                timer.schedule = .atTimeOfDay(hour: hour, minute: $0, second: second)
            }
        )
    }

    private var atSecond: Binding<Double> {
        Binding(
            get: { if case .atTimeOfDay(_, _, let second) = timer.schedule { second } else { 0 } },
            set: {
                guard case .atTimeOfDay(let hour, let minute, _) = timer.schedule else { return }
                timer.schedule = .atTimeOfDay(hour: hour, minute: minute, second: $0)
            }
        )
    }

    // MARK: - Action bindings

    private var actionIsScript: Binding<Bool> {
        Binding(
            get: { if case .script = timer.action { true } else { false } },
            set: { isScript in
                let text = currentActionText
                timer.action = isScript ? .script(text) : .send(text)
            }
        )
    }

    private var actionText: Binding<String> {
        Binding(
            get: { currentActionText },
            set: { text in
                timer.action = (timer.action.isScript ? .script(text) : .send(text))
            }
        )
    }

    private var currentActionText: String {
        switch timer.action {
        case .send(let text), .script(let text): text
        }
    }
}

private extension TimerAction {
    var isScript: Bool {
        if case .script = self { true } else { false }
    }
}
