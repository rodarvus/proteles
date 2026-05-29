import AppKit
import MudCore
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
            LoggingSettingsView()
                .tabItem { Label("Logging", systemImage: "doc.text") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
        }
        .frame(width: 480)
    }
}

/// Display + input behaviour.
private struct GeneralSettingsView: View {
    @AppStorage("omitBlankLines") private var omitBlankLines = false
    @AppStorage("commandSpellCheck") private var commandSpellCheck = false

    var body: some View {
        Form {
            Section {
                Toggle("Omit blank lines", isOn: $omitBlankLines)
                Text("Hide completely empty lines from the game output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Command Input") {
                Toggle("Check spelling as you type", isOn: $commandSpellCheck)
                Text("Show spell-check squiggles in the command line. Visual only — "
                    + "auto-correct and smart quotes stay off so commands like "
                    + "cast 'armor' are never altered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Output appearance.
private struct AppearanceSettingsView: View {
    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("outputFontSize") private var outputFontSize = 13.0
    @AppStorage("outputFontName") private var outputFontName = ""

    private var theme: Theme {
        Theme.with(id: themeID)
    }

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
            Section("Theme") {
                Picker("Colour theme", selection: $themeID) {
                    ForEach(Theme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                ThemePreview(theme: theme, fontSize: outputFontSize, fontName: outputFontName)
            }
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

/// A compact sample of game output rendered through a theme's palette + font.
private struct ThemePreview: View {
    let theme: Theme
    let fontSize: Double
    let fontName: String

    private var font: Font {
        fontName.isEmpty
            ? .system(size: fontSize, design: .monospaced)
            : .custom(fontName, fixedSize: fontSize)
    }

    var body: some View {
        let palette = theme.palette
        VStack(alignment: .leading, spacing: 1) {
            Text("Twisted Mind of a Psionicist")
                .foregroundStyle(color(palette.brightNamed[.cyan]))
            Text("[ Exits: north east south ]")
                .foregroundStyle(color(palette.brightNamed[.green]))
            Text("A psionicist ").foregroundStyle(color(palette.defaultForeground))
                + Text("(White Aura)").foregroundStyle(color(palette.brightNamed[.white]))
                + Text(" floats here.").foregroundStyle(color(palette.defaultForeground))
            Text("3004hp ").foregroundStyle(color(palette.brightNamed[.red]))
                + Text("2458mn ").foregroundStyle(color(palette.brightNamed[.blue]))
                + Text("1686mv").foregroundStyle(color(palette.brightNamed[.green]))
        }
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color(palette.defaultBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
    }

    private func color(_ rgb: RGB?) -> Color {
        guard let rgb else { return .primary }
        return Color(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
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

/// Readable session logs (distinct from the replayable recording).
private struct LoggingSettingsView: View {
    @AppStorage("sessionLogging") private var sessionLogging = false
    @AppStorage("sessionLogFormat") private var sessionLogFormat = "text"

    var body: some View {
        Form {
            Section {
                Toggle("Save a readable log of each session", isOn: $sessionLogging)
                Text("Write a per-session log you can read later. Takes effect on the "
                    + "next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Format") {
                Picker("Log format", selection: $sessionLogFormat) {
                    Text("Plain text").tag("text")
                    Text("HTML (preserves colour)").tag("html")
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Button("Reveal Logs in Finder") {
                    guard let directory = ProtelesApp.logsDirectory() else { return }
                    try? FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.open(directory)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// macOS notifications for tells / mentions.
private struct NotificationsSettingsView: View {
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notifyOnTells") private var notifyOnTells = true
    @AppStorage("notifyOnMention") private var notifyOnMention = true
    @AppStorage("notifyWhenFocused") private var notifyWhenFocused = false

    var body: some View {
        Form {
            Section {
                Toggle("Show notifications", isOn: $notificationsEnabled)
                Text("Post a macOS notification for important events while Proteles is "
                    + "in the background. You'll be asked for permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notify me about") {
                Toggle("Tells", isOn: $notifyOnTells)
                Toggle("My name mentioned on a channel", isOn: $notifyOnMention)
            }
            .disabled(!notificationsEnabled)
            Section("Delivery") {
                Toggle("Also notify while Proteles is in focus", isOn: $notifyWhenFocused)
                Text("By default, notifications are suppressed while Proteles is the "
                    + "active app. Turn this on to be notified even then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!notificationsEnabled)
        }
        .formStyle(.grouped)
    }
}
