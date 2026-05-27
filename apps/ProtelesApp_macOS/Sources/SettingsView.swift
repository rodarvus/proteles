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
    @AppStorage("outputFontName") private var outputFontName = ""

    /// Monospaced families that ship with macOS, plus the system default ("").
    private static let fontChoices: [(label: String, name: String)] = [
        ("System Monospaced", ""),
        ("Menlo", "Menlo"),
        ("Monaco", "Monaco"),
        ("Courier New", "Courier New"),
        ("PT Mono", "PTMono-Regular"),
        ("Andale Mono", "AndaleMono")
    ]

    private var sampleFont: Font {
        outputFontName.isEmpty
            ? .system(size: outputFontSize, design: .monospaced)
            : .custom(outputFontName, fixedSize: outputFontSize)
    }

    var body: some View {
        Form {
            Section("Game Output") {
                Picker("Font", selection: $outputFontName) {
                    ForEach(Self.fontChoices, id: \.name) { choice in
                        Text(choice.label).tag(choice.name)
                    }
                }
                LabeledContent("Size") {
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
                    .font(sampleFont)
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
    @AppStorage("keepAlive") private var keepAlive = true

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
                Toggle("Keep the connection alive when idle", isOn: $keepAlive)
                Text("Send a silent keep-alive periodically so Aardwolf doesn't "
                    + "disconnect a quiet session for being idle.")
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
