import MudCore
import SwiftUI

enum ScrollbackPreference {
    static let key = "scrollbackLineLimit"
    static let minimumLineCount = 100
    static let maximumLineCount = 1_000_000

    static var current: ScrollbackLimit {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int else {
            return .limited(ScrollbackLimit.defaultLineCount)
        }
        guard stored == 0 || minimumLineCount...maximumLineCount ~= stored else {
            return .limited(ScrollbackLimit.defaultLineCount)
        }
        return ScrollbackLimit(storedValue: stored)
    }
}

struct ScrollbackSettingsSection: View {
    private enum RetentionMode: String {
        case limited
        case unlimited
    }

    let session: SessionController

    @AppStorage(ScrollbackPreference.key) private var storedLimit =
        ScrollbackLimit.defaultLineCount
    @State private var draftLimit = ScrollbackLimit.defaultLineCount

    private var retentionMode: Binding<RetentionMode> {
        Binding(
            get: { storedLimit == 0 ? .unlimited : .limited },
            set: { mode in
                switch mode {
                case .limited: applyFiniteLimit()
                case .unlimited: apply(.unlimited)
                }
            }
        )
    }

    private var draftIsValid: Bool {
        ScrollbackPreference.minimumLineCount...ScrollbackPreference.maximumLineCount
            ~= draftLimit
    }

    private var retentionDescription: String {
        if storedLimit == 0 {
            return "Every main-output line is retained in memory. "
                + "Very long sessions can use substantial memory."
        }
        return "Reducing the limit discards the oldest main-output lines immediately. "
            + "Logs and recordings are unaffected."
    }

    var body: some View {
        Section("Scrollback") {
            Picker("Retention", selection: retentionMode) {
                Text("Limited").tag(RetentionMode.limited)
                Text("Unlimited").tag(RetentionMode.unlimited)
            }
            .pickerStyle(.segmented)

            if storedLimit != 0 {
                LabeledContent("Maximum lines") {
                    HStack(spacing: 8) {
                        TextField("", value: $draftLimit, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .onSubmit(applyFiniteLimit)
                        Button(action: applyFiniteLimit) {
                            Label("Apply", systemImage: "checkmark")
                        }
                        .disabled(!draftIsValid || draftLimit == storedLimit)
                    }
                }
            }

            Text(retentionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            let limit = ScrollbackPreference.current
            storedLimit = limit.storedValue
            if let lineCount = limit.lineCount { draftLimit = lineCount }
        }
    }

    private func applyFiniteLimit() {
        guard draftIsValid else { return }
        apply(.limited(draftLimit))
    }

    private func apply(_ limit: ScrollbackLimit) {
        storedLimit = limit.storedValue
        Task { await session.scrollbackStore.setLimit(limit) }
    }
}
