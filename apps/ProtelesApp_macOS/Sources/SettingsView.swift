import AppKit
import MudCore
import MudUI
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
            StatusBarSettingsView()
                .tabItem { Label("Status Bar", systemImage: "chart.bar.xaxis") }
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
            LoggingSettingsView()
                .tabItem { Label("Logging", systemImage: "doc.text") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            DiagnosticsSettingsView()
                .tabItem { Label("Diagnostics", systemImage: "ladybug") }
        }
        // A flexible frame (not a fixed width) so the Settings window is
        // resizable AND can't collapse: short tabs like Diagnostics used to
        // shrink the window to their intrinsic height, and a macOS Settings
        // window has no resize control to recover. The minimum keeps every tab
        // usable; tall tabs grow to the ideal/scroll within the Form.
        .frame(
            minWidth: 520,
            idealWidth: 580,
            maxWidth: 820,
            minHeight: 460,
            idealHeight: 540,
            maxHeight: 900
        )
    }
}

/// Display + input behaviour.
private struct GeneralSettingsView: View {
    @AppStorage("omitBlankLines") private var omitBlankLines = false
    @AppStorage("gagTagLines") private var gagTagLines = false
    @AppStorage("commandSpellCheck") private var commandSpellCheck = false
    @AppStorage("inputGhostHint") private var inputGhostHint = true
    @AppStorage("chat.timestamps") private var chatTimestamps = false
    @AppStorage("chat.timestampSeconds") private var chatTimestampSeconds = false

    var body: some View {
        Form {
            Section {
                Toggle("Omit blank lines", isOn: $omitBlankLines)
                Text("Hide completely empty lines from the game output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Hide Aardwolf tag lines", isOn: $gagTagLines)
                Text("Hide leftover protocol tag lines like {rname} / {coords} "
                    + "from the output. Display-only — plugins still receive them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Command Input") {
                Toggle("Suggest completions as you type", isOn: $inputGhostHint)
                Text("Show a greyed hint after the caret for the best completion. "
                    + "Press → or Tab to accept; Enter always sends exactly what you typed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Check spelling as you type", isOn: $commandSpellCheck)
                Text("Show spell-check squiggles in the command line. Visual only — "
                    + "auto-correct and smart quotes stay off so commands like "
                    + "cast 'armor' are never altered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Channels") {
                Toggle("Show timestamps", isOn: $chatTimestamps)
                Toggle("Include seconds", isOn: $chatTimestampSeconds)
                    .disabled(!chatTimestamps)
                Text("Prefix each Channels line with the time it arrived "
                    + "(your system 12/24-hour format).")
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

/// The bottom vitals bars: which of the six show, and how their numbers appear.
private struct StatusBarSettingsView: View {
    @AppStorage("statusBar.health") private var statusBarHealth = true
    @AppStorage("statusBar.mana") private var statusBarMana = true
    @AppStorage("statusBar.moves") private var statusBarMoves = true
    @AppStorage("statusBar.tnl") private var statusBarTNL = true
    @AppStorage("statusBar.enemy") private var statusBarEnemy = true
    @AppStorage("statusBar.align") private var statusBarAlign = true
    @AppStorage("statusBar.numberMode") private var statusBarNumberMode = StatusBarNumberMode.none.rawValue
    @AppStorage("statusBar.ticks") private var statusBarTicks = true
    @AppStorage("statusBar.color.health") private var statusColorHealth = "#00C000"
    @AppStorage("statusBar.color.mana") private var statusColorMana = "#2E6FFF"
    @AppStorage("statusBar.color.moves") private var statusColorMoves = "#FFFF00"
    @AppStorage("statusBar.color.tnl") private var statusColorTNL = "#CCCCCC"
    @AppStorage("statusBar.color.enemy") private var statusColorEnemy = "#FF3333"

    /// A `Binding<Color>` over a `#RRGGBB` `@AppStorage` hex string.
    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) },
            set: { hex.wrappedValue = $0.hexRGB }
        )
    }

    var body: some View {
        Form {
            Section("Bars") {
                barRow("Health", isOn: $statusBarHealth, color: $statusColorHealth)
                barRow("Mana", isOn: $statusBarMana, color: $statusColorMana)
                barRow("Moves", isOn: $statusBarMoves, color: $statusColorMoves)
                barRow("TNL", isOn: $statusBarTNL, color: $statusColorTNL)
                barRow("Enemy", isOn: $statusBarEnemy, color: $statusColorEnemy)
                barRow("Alignment", isOn: $statusBarAlign, color: nil)
                Text("Turn off every bar to hide the bottom bar entirely. The Enemy "
                    + "bar stays visible (greyed) when you're not in combat. The "
                    + "alignment marker is coloured by tier (good = yellow, evil = "
                    + "red, neutral = grey).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Numbers") {
                Picker("Show on each bar", selection: $statusBarNumberMode) {
                    Text("No text").tag(StatusBarNumberMode.none.rawValue)
                    Text("Raw number").tag(StatusBarNumberMode.number.rawValue)
                    Text("Percentage").tag(StatusBarNumberMode.percentage.rawValue)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Marks") {
                Toggle("Show 25 / 50 / 75% marks", isOn: $statusBarTicks)
                Text("Draw quarter marks across the HP/MP/MV/XP/Enemy bars. The "
                    + "alignment bar has its own scale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// One bar's row: a visibility toggle plus (when the bar has a single
    /// configurable colour) a colour well. The alignment bar passes `nil` —
    /// its marker is tier-coloured, not user-pickable.
    @ViewBuilder private func barRow(
        _ title: String,
        isOn: Binding<Bool>,
        color: Binding<String>?
    ) -> some View {
        if let color {
            LabeledContent {
                ColorPicker("", selection: colorBinding(color), supportsOpacity: false)
                    .labelsHidden()
            } label: {
                Toggle(title, isOn: isOn)
            }
        } else {
            Toggle(title, isOn: isOn)
        }
    }
}

private extension Color {
    /// Serialise to `#RRGGBB` for `@AppStorage` (sRGB, opacity dropped). Falls
    /// back to white if the components can't be resolved.
    var hexRGB: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
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
    @AppStorage("perWorldLogs") private var perWorldLogs = false
    @AppStorage("logRetention") private var logRetention = 30

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
            Section("Organisation") {
                Toggle("Separate logs per world", isOn: $perWorldLogs)
                Stepper("Keep the newest \(logRetention) logs", value: $logRetention, in: 5...500)
                Text("Older session logs are deleted on connect. Per-world logs go in a "
                    + "subfolder named for the world; the limit applies per folder. "
                    + "Passwords are never written to the log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            NotificationRulesSection()
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
