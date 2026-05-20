import MudCore
import SwiftUI

/// Detail pane of the Connection Manager: edits one ``WorldProfile``
/// (PLAN.md §8.4).
///
/// Binds directly to the model's profile (via
/// ``WorldsModel/binding(for:)``), so edits persist live. Surfaces
/// validation issues inline and disables Connect while any are present.
struct WorldEditorView: View {
    @Binding var profile: WorldProfile
    let isActive: Bool
    let onMakeActive: () -> Void
    let onConnect: () -> Void

    var body: some View {
        let issues = profile.validate()

        Form {
            Section("Connection") {
                TextField("Name", text: $profile.name)
                TextField("Host", text: $profile.host)
                TextField(
                    "Port",
                    value: $profile.port,
                    format: .number.grouping(.never)
                )
                Picker("Encoding", selection: $profile.encoding) {
                    Text("UTF-8").tag(TextEncoding.utf8)
                    Text("Latin-1 (ISO-8859-1)").tag(TextEncoding.latin1)
                }
            }

            Section("Behaviour") {
                Toggle("Auto-connect on launch", isOn: $profile.autoconnect)
            }

            if !issues.isEmpty {
                Section("Issues") {
                    ForEach(issues, id: \.self) { issue in
                        Label(Self.message(for: issue), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(profile.name.isEmpty ? "New World" : profile.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Make Active", action: onMakeActive)
                        .disabled(!issues.isEmpty)
                }
                Button("Connect", action: onConnect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!issues.isEmpty)
            }
        }
    }

    private static func message(for issue: WorldProfile.ValidationIssue) -> String {
        switch issue {
        case .emptyName: "Name can't be empty."
        case .emptyHost: "Host can't be empty."
        case .invalidPort: "Port must be between 1 and 65535."
        }
    }
}
