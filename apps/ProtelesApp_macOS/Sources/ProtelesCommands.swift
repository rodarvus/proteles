import AppKit
import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

private struct OutputFindActionKey: FocusedValueKey {
    typealias Value = (NSTextFinder.Action) -> Void
}

extension FocusedValues {
    /// "Run a find-bar action on this window's scrollback" — published by the
    /// main game window (D-104), consumed by Edit ▸ Find/Find Next/Find
    /// Previous, which grey out wherever there's no searchable output.
    var outputFindAction: ((NSTextFinder.Action) -> Void)? {
        get { self[OutputFindActionKey.self] }
        set { self[OutputFindActionKey.self] = newValue }
    }
}

/// Session + worlds commands, extracted so they can use
/// `@Environment(\.openWindow)` (which the `App` struct itself can't
/// hold) to surface the Worlds window.
struct ProtelesCommands: Commands {
    let session: SessionController
    let worlds: WorldsModel
    let scripts: ScriptsModel
    @Bindable var layout: LayoutStore
    /// Resume breadcrumb store (#42) — cleared on an explicit Disconnect so an
    /// intentional disconnect doesn't auto-reconnect on a later relaunch.
    var resumeStore: ResumeTokenStore?
    /// Presents the one-shot MUSHclient import (D-101) — owned by the app
    /// (it needs the import model), surfaced here so File reads top-down:
    /// connect, disconnect, worlds, import.
    var importFromMUSHclient: () -> Void
    @Environment(\.openWindow) private var openWindow
    /// Published by the key Scripts window (nil elsewhere) — backs the
    /// Edit ▸ Filter Scripts ⌥⌘F menu item, so the shortcut is discoverable
    /// in the menu bar (DESIGN.md §3.2) and greyed out where it can't act.
    @FocusedValue(\.scriptsFilterAction) private var scriptsFilterAction
    /// Published by the main game window — backs Edit ▸ Find (⌘F) over the
    /// scrollback (D-104).
    @FocusedValue(\.outputFindAction) private var outputFindAction
    /// Display preference, persisted in UserDefaults; ``ContentView`` mirrors
    /// the same key and pushes it to the session.
    @AppStorage("omitBlankLines") private var omitBlankLines = false
    /// Hide leftover Aardwolf tag lines ({rname}/{coords}/…) from the output;
    /// persisted in UserDefaults, pushed to the session by ``ContentView``.
    @AppStorage("gagTagLines") private var gagTagLines = false
    /// Rich Exits: make room exits (incl. custom exits) clickable in the main
    /// output. Persisted in UserDefaults; ``ContentView`` pushes it to the session.
    @AppStorage("richExits") private var richExits = false
    /// Keyboard "Navigation mode" (bare-key macros fire on an empty input).
    /// Shared with ``ContentView`` via the same UserDefaults key.
    @AppStorage("navigationMode") private var navigationMode = false

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            // Edit ▸ Find over the main window's scrollback (D-104): the
            // system find bar — incremental, highlight-all, case options,
            // and "Insert Pattern" wildcard tokens.
            Button("Find…") { outputFindAction?(.showFindInterface) }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(outputFindAction == nil)
            Button("Find Next") { outputFindAction?(.nextMatch) }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(outputFindAction == nil)
            Button("Find Previous") { outputFindAction?(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(outputFindAction == nil)

            Divider()

            // Edit ▸ Filter Scripts (⌥⌘F, the Mail convention — ⌘F finds in
            // content, ⌥⌘F focuses the list filter): focus the filter field
            // of the frontmost Scripts tab. Enabled while a Scripts window
            // is key.
            Button("Filter Scripts") { scriptsFilterAction?() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(scriptsFilterAction == nil)
        }

        // File: the session + data lifecycle (connect, disconnect, worlds,
        // import). Replaces ⌘N — Proteles has no "new document". The editor
        // and tool windows live under Tools, not here (#35 menu pass).
        CommandGroup(replacing: .newItem) {
            // Surface WHICH world ⌘K connects to (the Worlds window's active
            // selection) right on the menu item.
            Button(worlds.activeProfile.map { "Connect to \($0.name)" } ?? "Connect") {
                let session = session
                let worlds = worlds
                let scripts = scripts
                Task { @MainActor in
                    guard let active = worlds.activeProfile else { return }
                    ProtelesApp.logContext.worldName = active.name
                    await scripts.load(forProfile: active.id)
                    try? await session.connect(
                        to: active.endpoint,
                        autologin: worlds.autologinPlan(for: active)
                    )
                }
            }
            .keyboardShortcut("K", modifiers: [.command])

            Button("Disconnect") {
                let session = session
                // An explicit disconnect is intentional — drop the resume
                // breadcrumb so a later relaunch doesn't auto-reconnect (#42).
                resumeStore?.clear()
                Task { await session.disconnect() }
            }
            .keyboardShortcut("D", modifiers: [.command, .shift])

            Divider()

            Button("Manage Worlds…") {
                openWindow(id: ProtelesApp.worldsWindowID)
            }
            .keyboardShortcut("M", modifiers: [.command, .shift])

            Divider()

            Button("Import from MUSHclient…") { importFromMUSHclient() }
        }

        // Tools: the editor/inspector windows. A dedicated menu (between View
        // and Window) instead of crowding File — these open workspaces, they
        // don't act on the session.
        CommandMenu("Tools") {
            Button("Scripts…") {
                openWindow(id: ProtelesApp.scriptsWindowID)
            }
            .keyboardShortcut("T", modifiers: [.command, .shift])

            Button("Plugins…") {
                openWindow(id: ProtelesApp.pluginsWindowID)
            }
            .keyboardShortcut("P", modifiers: [.command, .shift])

            Button("Lua Console…") {
                openWindow(id: ProtelesApp.luaConsoleWindowID)
            }
            .keyboardShortcut("Y", modifiers: [.command, .shift])

            Divider()

            Button("Levels") { openWindow(id: ProtelesApp.levelsWindowID) }
                .keyboardShortcut("L", modifiers: [.command, .shift])

            Button("Game Help") { openWindow(id: ProtelesApp.helpWindowID) }
                .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            // ⌥⎋ is macOS's own speak-selection start/stop convention; the
            // package binds Ctrl+Space, which macOS reserves for input
            // sources. Flushes the whole TTS queue (#9).
            Button("Stop Speaking") {
                Task { await session.stopSpeaking() }
            }
            .keyboardShortcut(.escape, modifiers: [.option])
        }

        // Panels live in the main-window tiled dock (not separate windows, which
        // could fall behind the game window). Toggling shows/hides each in place.
        // Merge into the *existing* system View menu (which holds Enter Full
        // Screen) via `.sidebar` rather than a `CommandMenu("View")`, which would
        // create a second top-level View menu.
        CommandGroup(after: .sidebar) {
            Toggle(isOn: panelBinding(.map)) { Text("Map") }
                .keyboardShortcut("B", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.asciiMap)) { Text("Text Map") }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.channels)) { Text("Channels") }
                .keyboardShortcut("J", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.hunt)) { Text("Search & Destroy") }
                .keyboardShortcut("U", modifiers: [.command, .shift])
            Toggle(isOn: panelBinding(.info)) { Text("Character") }
                .keyboardShortcut("I", modifiers: [.command, .shift])

            Divider()

            Button("Reset Layout") { layout.resetToDefault() }

            Divider()

            // Display preference (native equivalent of Omit_Blank_Lines): drop
            // completely-empty MUD lines from the main output. Persists via
            // @AppStorage; ContentView pushes the value to the session.
            Toggle("Omit Blank Lines", isOn: $omitBlankLines)

            // Strip leftover Aardwolf telnet-102 tag markers ({rname}/{coords}/…)
            // from the output. Display-only + post-processing, so plugins still
            // receive them; persists via @AppStorage, pushed by ContentView.
            // (Named to match Settings ▸ Appearance ▸ "Clean Aardwolf tag markers".)
            Toggle("Clean Aardwolf Tags", isOn: $gagTagLines)

            // Make room exits (incl. custom exits) clickable in the main output
            // (native equivalent of Aardwolf-Rich-Exits, no miniwindow). Enabling
            // turns on Aardwolf's `tags exits` so the line is detectable.
            Toggle("Rich Exits", isOn: $richExits)

            Divider()

            // Keyboard navigation mode: while on, bare-key macros fire on an
            // empty input line (keypad/chord macros fire regardless). A "NAV"
            // chip on the command input shows when it's active.
            Toggle("Navigation Mode", isOn: $navigationMode)
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }

    /// A binding that reflects a panel's visibility and toggles it on change.
    private func panelBinding(_ kind: PanelKind) -> Binding<Bool> {
        Binding(get: { layout.isVisible(kind) }, set: { _ in layout.toggle(kind) })
    }
}
