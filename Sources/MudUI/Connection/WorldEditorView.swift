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

    /// Reads the stored autologin password for this profile (from the
    /// Keychain, via ``WorldsModel``). The password is *not* part of
    /// ``WorldProfile`` — it never touches `profiles.json`.
    let loadPassword: () -> String

    /// Persists the autologin password for this profile.
    let savePassword: (String) -> Void

    @State private var password: String = ""

    var body: some View {
        let issues = profile.validate()

        Form {
            Section {
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
            } header: {
                Text("Connection")
            } footer: {
                Text("Changes are saved automatically.")
            }

            Section("Behaviour") {
                Toggle("Auto-connect on launch", isOn: $profile.autoconnect)
            }

            autologinSection

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
        .task(id: profile.id) { password = loadPassword() }
        .onChange(of: password) { _, newValue in savePassword(newValue) }
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

    private var autologinSection: some View {
        Section("Autologin") {
            Toggle("Log in automatically", isOn: autologinEnabled)
            if profile.autologin != nil {
                TextField("Character name", text: usernameBinding)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Text("Sent at the login prompts. The password is stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Toggle binding: presence of ``WorldProfile/autologin`` is the
    /// enabled state. Turning it off clears the descriptor and the
    /// stored password.
    private var autologinEnabled: Binding<Bool> {
        Binding(
            get: { profile.autologin != nil },
            set: { isOn in
                if isOn {
                    if profile.autologin == nil {
                        profile.autologin = Autologin(username: "")
                    }
                } else {
                    profile.autologin = nil
                    password = ""
                }
            }
        )
    }

    /// Username binding into the optional ``Autologin`` (only shown while
    /// the descriptor exists, so the optional-chained setter always
    /// lands).
    private var usernameBinding: Binding<String> {
        Binding(
            get: { profile.autologin?.username ?? "" },
            set: { profile.autologin?.username = $0 }
        )
    }

    private static func message(for issue: WorldProfile.ValidationIssue) -> String {
        switch issue {
        case .emptyName: "Name can't be empty."
        case .emptyHost: "Host can't be empty."
        case .invalidPort: "Port must be between 1 and 65535."
        }
    }
}
