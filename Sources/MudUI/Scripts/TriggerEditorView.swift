import MudCore
import SwiftUI

/// Detail editor for one ``Trigger``. Binds live through
/// ``ScriptsModel/binding(forTrigger:)`` so edits persist and apply to the
/// running session immediately.
struct TriggerEditorView: View {
    @Binding var trigger: Trigger
    @State private var showOptions = false

    var body: some View {
        Form {
            Section("Match") {
                Picker("Type", selection: patternKind) {
                    ForEach(PatternKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Pattern", text: patternText)
                    .font(.body.monospaced())
                Toggle("Case sensitive", isOn: $trigger.caseSensitive)
                if trigger.pattern.isInvalid(caseSensitive: trigger.caseSensitive) {
                    Label(
                        "This pattern won't compile — check the regex.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Section("Action") {
                TextField("Send to MUD", text: $trigger.sendText.orEmpty())
                TextField("Script (Lua)", text: $trigger.script.orEmpty(), axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(3...10)
            }

            Section("Test") {
                PatternTestView(pattern: trigger.pattern, caseSensitive: trigger.caseSensitive)
            }

            Section {
                DisclosureGroup("Options", isExpanded: $showOptions) {
                    Toggle("Enabled", isOn: $trigger.enabled)
                    Toggle("Gag (hide the matched line)", isOn: $trigger.gag)
                    Toggle("Keep evaluating later triggers", isOn: $trigger.continueEvaluation)
                    Toggle("One-shot (remove after firing)", isOn: $trigger.oneShot)
                    TextField("Sequence", value: $trigger.sequence, format: .number.grouping(.never))
                    TextField("Group", text: $trigger.group.orEmpty())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }

    private var title: String {
        let text = trigger.pattern.text
        return text.isEmpty ? "New Trigger" : text
    }

    private var patternKind: Binding<PatternKind> {
        Binding(
            get: { trigger.pattern.kind },
            set: { trigger.pattern = .make(kind: $0, text: trigger.pattern.text) }
        )
    }

    private var patternText: Binding<String> {
        Binding(
            get: { trigger.pattern.text },
            set: { trigger.pattern = .make(kind: trigger.pattern.kind, text: $0) }
        )
    }
}
