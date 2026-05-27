import SwiftUI

/// First-pass Preferences (⌘,). A tabbed Settings window; both controls here
/// apply live (they drive `@AppStorage` keys that `ContentView` observes).
/// Structured to grow — Connection, Scripts, and theming tabs slot in later.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
        }
        .frame(width: 480)
    }
}

/// Display behaviour.
private struct GeneralSettingsView: View {
    @AppStorage("omitBlankLines") private var omitBlankLines = false

    var body: some View {
        Form {
            Section {
                Toggle("Omit blank lines", isOn: $omitBlankLines)
                Text("Hide completely empty lines from the game output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Output appearance.
private struct AppearanceSettingsView: View {
    @AppStorage("outputFontSize") private var outputFontSize = 13.0

    var body: some View {
        Form {
            Section("Game Output") {
                LabeledContent("Font size") {
                    HStack(spacing: 10) {
                        Slider(value: $outputFontSize, in: 9...24, step: 1)
                            .frame(width: 180)
                        Text("\(Int(outputFontSize)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Text("The quick brown fox jumps over the lazy dog")
                    .font(.system(size: outputFontSize, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Connection behaviour.
private struct ConnectionSettingsView: View {
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("autoRecordSessions") private var autoRecordSessions = true

    var body: some View {
        Form {
            Section {
                Toggle("Reconnect automatically", isOn: $autoReconnect)
                Text("After a dropped connection, retry with increasing backoff. "
                    + "Takes effect on the next disconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Record sessions automatically", isOn: $autoRecordSessions)
                Text("Save a replayable capture of each session locally (under the "
                    + "app's Application Support folder). Takes effect on the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
