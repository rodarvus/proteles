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

/// Preferences ▸ Notifications — the custom-rule editor (#14). Phase-2 keyword /
/// channel rules plus phase-3 regex keywords, low-HP and quest-ready triggers,
/// per-rule sound, and optional title/body templates. Persisted as JSON in
/// UserDefaults.
struct NotificationRulesSection: View {
    @AppStorage(NotificationRulesStorage.key) private var rulesData = Data()
    @State private var draftKind: DraftKind = .keyword
    @State private var draftText = ""
    @State private var draftPercent = 25

    private enum DraftKind: String, CaseIterable, Identifiable {
        case keyword, regex, channel, hpBelow, questReady
        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .keyword: "Keyword"
            case .regex: "Regex"
            case .channel: "Channel"
            case .hpBelow: "HP below"
            case .questReady: "Quest ready"
            }
        }

        var needsText: Bool {
            self == .keyword || self == .regex || self == .channel
        }
    }

    private var rules: [NotificationRule] {
        .decoded(from: rulesData)
    }

    private func setRules(_ rules: [NotificationRule]) {
        rulesData = rules.encoded
    }

    /// A binding over one field of the rule with `id`, writing the whole set back.
    private func field<Value>(
        _ rule: NotificationRule,
        _ keyPath: WritableKeyPath<NotificationRule, Value>
    ) -> Binding<Value> {
        Binding(
            get: { (rules.first { $0.id == rule.id } ?? rule)[keyPath: keyPath] },
            set: { newValue in
                var all = rules
                guard let index = all.firstIndex(where: { $0.id == rule.id }) else { return }
                all[index][keyPath: keyPath] = newValue
                setRules(all)
            }
        )
    }

    var body: some View {
        Section("Custom rules") {
            if rules.isEmpty {
                Text("Add a keyword/regex (any output line), a channel, a low-HP alert, or quest-ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rules) { ruleRow($0) }
            addRow
        }
    }

    private func ruleRow(_ rule: NotificationRule) -> some View {
        DisclosureGroup {
            Picker("Sound", selection: field(rule, \.sound)) {
                ForEach(NotificationRule.Sound.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            if case .keyword = rule.trigger {
                Toggle("Match as regular expression", isOn: field(rule, \.regex))
            }
            TextField("Title (optional)", text: field(rule, \.titleTemplate))
            TextField(
                "Body (optional, tokens: {line} {player} {channel} {percent})",
                text: field(rule, \.bodyTemplate)
            )
        } label: {
            HStack {
                Toggle("", isOn: field(rule, \.enabled)).labelsHidden()
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
    }

    private var addRow: some View {
        HStack {
            Picker("", selection: $draftKind) {
                ForEach(DraftKind.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().fixedSize()
            if draftKind.needsText {
                TextField(draftKind == .channel ? "channel name" : "text to match", text: $draftText)
                    .onSubmit(addDraft)
            } else if draftKind == .hpBelow {
                // A compact value label + bare stepper arrows — a string-label
                // Stepper is wide and pushed "Add" off the right edge.
                Text("\(draftPercent)%").monospacedDigit().frame(width: 40, alignment: .leading)
                Stepper("", value: $draftPercent, in: 1...99, step: 5)
                    .labelsHidden().fixedSize()
            }
            Spacer()
            Button("Add", action: addDraft).disabled(!canAdd)
        }
    }

    private var canAdd: Bool {
        draftKind.needsText ? !draftText.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    private func addDraft() {
        guard canAdd else { return }
        let text = draftText.trimmingCharacters(in: .whitespaces)
        let rule = switch draftKind {
        case .keyword: NotificationRule(trigger: .keyword(text))
        case .regex: NotificationRule(trigger: .keyword(text), regex: true)
        case .channel: NotificationRule(trigger: .channel(text))
        case .hpBelow: NotificationRule(trigger: .hpBelow(draftPercent))
        case .questReady: NotificationRule(trigger: .questReady)
        }
        setRules(rules + [rule])
        draftText = ""
    }
}
