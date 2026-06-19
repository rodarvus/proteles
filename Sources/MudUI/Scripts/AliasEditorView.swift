import MudCore
import SwiftUI

/// Detail editor for one ``Alias``. Binds live through
/// ``ScriptsModel/binding(forAlias:)``.
struct AliasEditorView: View {
    @Binding var alias: Alias
    @State private var showOptions = false

    var body: some View {
        Form {
            Section("Match") {
                Picker("Type", selection: patternKind) {
                    ForEach(PatternKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Pattern", text: patternText)
                    .font(.body.monospaced())
                Toggle("Case sensitive", isOn: $alias.caseSensitive)
                if alias.pattern.isInvalid(caseSensitive: alias.caseSensitive) {
                    Label(
                        "This pattern won't compile — check the regex.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }

            Section("Test") {
                PatternTestView(pattern: alias.pattern, caseSensitive: alias.caseSensitive)
            }

            Section("Action") {
                Picker("Send to", selection: $alias.sendTo) {
                    Text(AliasTarget.world.label).tag(AliasTarget.world)
                    Text(AliasTarget.execute.label).tag(AliasTarget.execute)
                    Text(AliasTarget.script.label).tag(AliasTarget.script)
                    Text(AliasTarget.output.label).tag(AliasTarget.output)
                }
                CommandBodyEditor(
                    title: alias.sendTo == .script ? "Script (Lua)" : "Expansion",
                    text: $alias.sendText.orEmpty()
                )
            }

            Section {
                DisclosureGroup("Options", isExpanded: $showOptions) {
                    Toggle("Enabled", isOn: $alias.enabled)
                    Toggle("Keep evaluating later aliases", isOn: $alias.keepEvaluating)
                    Toggle("One-shot (remove after firing)", isOn: $alias.oneShot)
                    TextField("Sequence", value: $alias.sequence, format: .number.grouping(.never))
                    TextField("Group", text: $alias.group.orEmpty())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }

    private var title: String {
        let text = alias.pattern.text
        return text.isEmpty ? "New Alias" : text
    }

    private var patternKind: Binding<PatternKind> {
        Binding(
            get: { alias.pattern.kind },
            set: { alias.pattern = .make(kind: $0, text: alias.pattern.text) }
        )
    }

    private var patternText: Binding<String> {
        Binding(
            get: { alias.pattern.text },
            set: { alias.pattern = .make(kind: alias.pattern.kind, text: $0) }
        )
    }
}
