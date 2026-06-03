import MudCore
import SwiftUI

/// `[NotificationRule]` ↔ JSON `Data` for `@AppStorage`-backed persistence, so
/// the Preferences window and the main window observe the same global set via
/// UserDefaults (consistent with the phase-1 notification prefs).
extension [NotificationRule] {
    var encoded: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decoded(from data: Data) -> [NotificationRule] {
        (try? JSONDecoder().decode([NotificationRule].self, from: data)) ?? []
    }
}

/// The UserDefaults key the rule editor + the session-push task share.
enum NotificationRulesStorage {
    static let key = "notificationRulesData"
}

/// Preferences ▸ Notifications — the phase-2 custom-rule editor (#14): keyword
/// rules (match any output line) and channel rules (any chat on a named
/// channel), each with an enable toggle. Persisted as JSON in UserDefaults.
struct NotificationRulesSection: View {
    @AppStorage(NotificationRulesStorage.key) private var rulesData = Data()
    @State private var draftText = ""
    @State private var draftKind: DraftKind = .keyword

    private enum DraftKind: String, CaseIterable, Identifiable {
        case keyword, channel
        var id: String {
            rawValue
        }

        var title: String {
            self == .keyword ? "Keyword" : "Channel"
        }

        var prompt: String {
            self == .keyword ? "text to match in output" : "channel name"
        }
    }

    private var rules: [NotificationRule] {
        .decoded(from: rulesData)
    }

    private func setRules(_ rules: [NotificationRule]) {
        rulesData = rules.encoded
    }

    var body: some View {
        Section("Custom rules") {
            if rules.isEmpty {
                Text("Add a keyword (alerts on any output line) or a channel (alerts on its chat).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                ruleRow(rule)
            }
            addRow
        }
    }

    private func ruleRow(_ rule: NotificationRule) -> some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { isOn in
                    var updated = rules
                    if let index = updated.firstIndex(where: { $0.id == rule.id }) {
                        updated[index].enabled = isOn
                        setRules(updated)
                    }
                }
            )).labelsHidden()
            Text(rule.displayLabel).lineLimit(1)
            Spacer()
            Button(role: .destructive) {
                setRules(rules.filter { $0.id != rule.id })
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private var addRow: some View {
        HStack {
            Picker("", selection: $draftKind) {
                ForEach(DraftKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            TextField(draftKind.prompt, text: $draftText)
                .onSubmit(addDraft)
            Button("Add", action: addDraft)
                .disabled(draftText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func addDraft() {
        let text = draftText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let trigger: NotificationRule.Trigger = draftKind == .keyword ? .keyword(text) : .channel(text)
        setRules(rules + [NotificationRule(trigger: trigger)])
        draftText = ""
    }
}
