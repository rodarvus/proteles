import AppKit
import MudCore
import MudUI
import SwiftUI

/// Preferences (⌘,) — seven tabs, each answering one question (#35 review):
/// **Appearance** (what the output looks like), **Status Bar** (the vitals
/// bars), **Input** (the command line), **Panels** (the floating/docked
/// panels), **Session** (the wire + what's kept on disk), **Notifications**,
/// and **Development** (recording, databases, crash diagnostics). There is
/// deliberately no "General" grab-bag: every setting lives where you'd look
/// for it. All controls apply live (they drive `@AppStorage` keys their
/// consumers observe).
struct SettingsView: View {
    // Models for the Development tab's recording + database actions.
    let session: SessionController
    let map: MapPanelModel
    let snd: SnDPanelModel
    let pluginDBs: PluginDatabasesModel

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "textformat.size") }
            StatusBarSettingsView()
                .tabItem { Label("Status Bar", systemImage: "chart.bar.xaxis") }
            InputSettingsView()
                .tabItem { Label("Input", systemImage: "keyboard") }
            PanelsSettingsView()
                .tabItem { Label("Panels", systemImage: "rectangle.3.group") }
            SessionSettingsView()
                .tabItem { Label("Session", systemImage: "network") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            DevelopmentSettingsView(session: session, map: map, snd: snd, pluginDBs: pluginDBs)
                .tabItem { Label("Development", systemImage: "hammer") }
        }
        // A flexible frame (not a fixed width) so the Settings window is
        // resizable AND can't collapse: short tabs used to shrink the window
        // to their intrinsic height, and a macOS Settings window has no
        // resize control to recover. The minimum keeps every tab usable;
        // tall tabs grow to the ideal/scroll within the Form.
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

/// What the game output looks like: theme, font, and the display-only
/// clean-ups applied to incoming lines.
private struct AppearanceSettingsView: View {
    @AppStorage("themeID") private var themeID = Theme.default.id
    @AppStorage("outputFontSize") private var outputFontSize = 13.0
    @AppStorage("outputFontName") private var outputFontName = "JetBrains Mono NL"
    @AppStorage("omitBlankLines") private var omitBlankLines = false
    @AppStorage("gagTagLines") private var gagTagLines = false

    private var theme: Theme {
        Theme.with(id: themeID)
    }

    /// Bundled fonts (registered at launch from Resources/Fonts; OFL except Hack
    /// which is its own permissive license — ligatures disabled in the renderer),
    /// the system default (""), and the monospaced families macOS ships.
    private static let fontChoices: [(label: String, name: String)] = [
        ("System Monospaced", ""),
        // Bundled, for evaluation:
        ("JetBrains Mono", "JetBrains Mono NL"),
        ("Source Code Pro", "Source Code Pro"),
        ("Fira Code", "Fira Code"),
        ("Monaspace Neon", "Monaspace Neon Frozen"),
        ("Cascadia Code", "Cascadia Code"),
        ("Hack", "Hack"),
        // Installed with macOS:
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
                .help("The colour palette for game output and panels")
                ThemePreview(theme: theme, fontSize: outputFontSize, fontName: outputFontName)
            }
            Section("Game Output") {
                Picker("Font", selection: $outputFontName) {
                    ForEach(Self.fontChoices, id: \.name) { choice in
                        Text(choice.label).tag(choice.name)
                    }
                }
                .help("The monospaced font for the game output")
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
            Section("Clean-ups") {
                Toggle("Omit blank lines", isOn: $omitBlankLines)
                    .help("Hide completely empty lines from the game output")
                Toggle("Clean Aardwolf tag markers", isOn: $gagTagLines)
                    .help("Strip {rname}-style markers; hide pure-data tags like {coords}")
                Text("Display-only — plugins and triggers still receive the raw "
                    + "lines. Also in the View menu.")
                    .font(.caption)
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
                    .help("Draw quarter marks across the bars")
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

/// The command line: completion, spelling, and keyboard navigation. (Keypad
/// bindings and macros are content, not preferences — they live in Scripts.)
private struct InputSettingsView: View {
    @AppStorage("inputGhostHint") private var inputGhostHint = true
    @AppStorage("commandSpellCheck") private var commandSpellCheck = false
    @AppStorage("navigationMode") private var navigationMode = false
    @AppStorage("scriptErrorsInOutput") private var scriptErrorsInOutput = true

    var body: some View {
        Form {
            Section("Completion") {
                Toggle("Suggest completions as you type", isOn: $inputGhostHint)
                    .help("A greyed hint after the caret; → or Tab accepts it")
                Text("Show a greyed hint after the caret for the best completion. "
                    + "Press → or Tab to accept; Enter always sends exactly what you typed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Spelling") {
                Toggle("Check spelling as you type", isOn: $commandSpellCheck)
                    .help("Visual squiggles only — commands are never auto-corrected")
                Text("Show spell-check squiggles in the command line. Visual only — "
                    + "auto-correct and smart quotes stay off so commands like "
                    + "cast 'armor' are never altered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Navigation mode", isOn: $navigationMode)
                    .help("Bare-key macros fire while the input line is empty (⌥⌘N)")
                Text("While on, bare-key macros fire when the input line is empty "
                    + "(keypad and modifier macros fire regardless). Also in the "
                    + "View menu (⌥⌘N) — a NAV chip on the input shows it's active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Keypad bindings, macros, and aliases are edited in "
                    + "Tools ▸ Scripts (⇧⌘T).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Scripting") {
                Toggle("Show script errors in the main output", isOn: $scriptErrorsInOutput)
                    .help("Off: errors go only to the Lua Console (Tools ▸ Lua Console)")
                Text("Plugin and trigger errors always stream to the Lua Console "
                    + "with the plugin that raised them; this also echoes each as "
                    + "a red note in the game output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The floating/docked panels around the game output.
private struct PanelsSettingsView: View {
    // Floating-panel translucency — read by FloatingMiniWindow (MudUI).
    @AppStorage("floatingPanelTranslucent") private var floatingPanelTranslucent = false
    @AppStorage("floatingPanelAlpha") private var floatingPanelAlpha = 0.7
    @AppStorage("chat.timestamps") private var chatTimestamps = false
    @AppStorage("chat.timestampSeconds") private var chatTimestampSeconds = false

    var body: some View {
        Form {
            Section("Floating Panels") {
                Toggle("Translucent floating panels", isOn: $floatingPanelTranslucent)
                    .help("Fade the panel backdrop so game text shows through")
                LabeledContent("Opacity") {
                    HStack(spacing: 10) {
                        Slider(value: $floatingPanelAlpha, in: 0.3...1.0)
                            .frame(width: 180)
                        Text("\(Int(floatingPanelAlpha * 100)) %")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!floatingPanelTranslucent)
                Text("Fades the panel background only — text stays at full "
                    + "contrast. Applies immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Channels") {
                Toggle("Show timestamps", isOn: $chatTimestamps)
                    .help("Prefix each Channels line with its arrival time")
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

/// The wire and what's kept on disk: reconnect, keep-alive, session logs.
private struct SessionSettingsView: View {
    @AppStorage("autoReconnect") private var autoReconnect = true
    @AppStorage("keepAlive") private var keepAlive = true
    @AppStorage("sessionLogging") private var sessionLogging = false
    @AppStorage("sessionLogFormat") private var sessionLogFormat = "text"
    @AppStorage("perWorldLogs") private var perWorldLogs = false
    @AppStorage("logRetention") private var logRetention = 30

    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Reconnect automatically", isOn: $autoReconnect)
                    .help("Retry with increasing backoff after a dropped connection")
                Text("After a dropped connection, retry with increasing backoff. "
                    + "Takes effect on the next disconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep the connection alive when idle", isOn: $keepAlive)
                    .help("A silent keep-alive stops Aardwolf's idle disconnect")
                Text("Send a silent keep-alive periodically so Aardwolf doesn't "
                    + "disconnect a quiet session for being idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Session Logs") {
                Toggle("Save a readable log of each session", isOn: $sessionLogging)
                    .help("A per-session text/HTML log (distinct from the replayable recording)")
                Picker("Log format", selection: $sessionLogFormat) {
                    Text("Plain text").tag("text")
                    Text("HTML (preserves colour)").tag("html")
                }
                .pickerStyle(.radioGroup)
                .disabled(!sessionLogging)
                Text("Write a per-session log you can read later. Takes effect on "
                    + "the next connection. Passwords are never written to the log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Organisation") {
                Toggle("Separate logs per world", isOn: $perWorldLogs)
                    .help("One subfolder per world")
                Stepper("Keep the newest \(logRetention) logs", value: $logRetention, in: 5...500)
                    .help("Older logs are deleted on connect")
                Text("Older session logs are deleted on connect. Per-world logs go "
                    + "in a subfolder named for the world; the limit applies per folder.")
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
                    .help("macOS notifications for important events while in the background")
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
                    .help("By default notifications are suppressed while Proteles is active")
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
