import MudCore
import Observation
import SwiftUI

/// `@Observable` view-model bridging a world's ``ScriptStore`` to SwiftUI
/// and keeping the live ``SessionController`` in sync (PLAN.md §8.6).
///
/// Mirrors ``WorldsModel``: the store is the persisted source of truth on
/// its own actor; this model holds main-actor copies the editor binds to,
/// and forwards mutations to *both* the store (so they persist) and the
/// running session's engine (so they take effect immediately — a trigger
/// you add fires on the next matching line without reconnecting).
///
/// Loading a profile resets the live set wholesale via
/// ``SessionController/loadScripts(_:)``; subsequent edits apply
/// incrementally (the engine has no in-place update, so an edit is a
/// remove-then-add of the one item).
@MainActor
@Observable
public final class ScriptsModel {
    public private(set) var triggers: [Trigger] = []
    public private(set) var aliases: [Alias] = []
    public private(set) var timers: [MudTimer] = []
    public private(set) var macros: [Macro] = []
    /// The command-button bar (#15) — mirrored from the store, edited via the
    /// Buttons tab + the scripting API, shown in the command-bar panel.
    public private(set) var buttonBar = ButtonBar()
    /// The keypad command grid (D-102) — mirrored from the store, edited via
    /// the Keypad tab, matched by the key monitor *behind* macros (macros →
    /// keypad → button hotkeys). Mutations live in `ScriptsModel+Keypad.swift`.
    public private(set) var keypad = Keypad()
    /// Transient on/off state for toggle buttons (not persisted).
    public var buttonToggleStates: [UUID: Bool] = [:]

    public var selectedTriggerID: UUID?
    public var selectedAliasID: UUID?
    public var selectedTimerID: UUID?
    public var selectedMacroID: UUID?
    public var selectedButtonGroupID: UUID?
    public var selectedButtonID: UUID?
    /// Bumped by ``requestButtonsTab()`` — the Scripts window watches it and
    /// switches to the Buttons tab (the command-bar panel's empty state links
    /// straight to the editor, D-106).
    public private(set) var buttonsTabRequests = 0

    /// Ask the Scripts window (open or about to open) to show the Buttons tab.
    public func requestButtonsTab() {
        buttonsTabRequests += 1
    }

    /// Which script kinds are shared across characters (for the editor toggles).
    public private(set) var scriptScope = ScriptScope()

    // Internal (not private) so the button-bar extension (ScriptsModel+Buttons)
    // can persist + fire through the same store/session/refresh path.
    let session: SessionController
    var store: ScriptStore?
    private var profileID: UUID?
    /// Live keypress→action lookup, kept in sync with ``macros``. Held here
    /// (main-actor, value type) so the command field's key monitor can match
    /// a chord inline; the session has no macro engine of its own.
    private var macroEngine = MacroEngine()
    /// Accelerators registered by plugins (`Accelerator`/`AcceleratorTo`) —
    /// transient (never persisted), re-registered when plugins load. Kept apart
    /// from the user's stored macros so a user-macro edit doesn't drop them; both
    /// are merged into ``macroEngine`` by ``syncMacroEngine()``.
    private var pluginMacros: [Macro] = []

    public init(session: SessionController) {
        self.session = session
    }

    /// Whether the (separately-installed) Search-and-Destroy plugin is present.
    public var isSearchAndDestroyInstalled: Bool {
        SearchAndDestroyAssets.isInstalled
    }

    /// Load a profile's scripts: build its store, mirror the document, and
    /// install the whole set into the live session. Idempotent per profile.
    public func load(forProfile id: UUID) async {
        let character = await Self.characterKey(forProfile: id)
        guard let scriptsDir = try? ProtelesPaths.scriptsDirectory() else { return }
        let store = ScriptStore(directory: scriptsDir, character: character)
        try? await store.load()
        self.store = store
        profileID = id
        pluginMacros = [] // a new world reload re-registers plugin accelerators
        // Plugin Accelerator/AcceleratorTo keybinds register into our MacroEngine.
        await session.scriptEngine?.setAcceleratorRegistrar { [weak self] macro in
            Task { @MainActor in self?.addPluginMacro(macro) }
        }
        scriptScope = await store.scope
        await migrateAndSeedKeypad(store: store, profileID: id)
        await refresh()
        await session.loadScripts(store.document)
        // Hydrate persisted plugin/script variables before loading plugins,
        // so their OnPluginInstall reads saved values (and the store is then
        // written through as variables change).
        if let variableURL = try? VariableStore.defaultStoreURL(forProfile: id) {
            await session.attachVariableStore(VariableStore(url: variableURL))
        }
        // Hydrate the native plugins' per-world state (e.g. #sub/#gag rules)
        // and enabled flags.
        if let nativeURL = try? NativePluginStore.defaultStoreURL(forProfile: id) {
            await session.attachNativePluginStore(NativePluginStore(url: nativeURL))
        }
        // The lsqlite3 sandbox root spans the whole ~/Documents/Proteles tree, so
        // each plugin can reach its own per-character data dir (and the global
        // Databases/) while nothing outside is reachable. Attach before loading.
        if let home = try? ProtelesPaths.home() {
            await session.attachWorldDataDirectory(home.path)
        }
        // Core features (D-107): each profile can opt out of the mapper /
        // dinv / leveldb / S&D — consult the store before attaching each.
        let disabledFeatures = await CoreFeatureStore.disabledFeatures(forProfile: id)
        // Attach the live map, backed by the global Databases/Aardwolf.db.
        if !disabledFeatures.contains("mapper"), let mapper = Self.makeMapper() {
            await session.attachMapper(mapper)
        }
        // Attach the native Search-and-Destroy host (if installed): its own
        // sandboxed runtime, pointed at the global Databases/ dir (its
        // SnDdb.db). Inert when S&D isn't installed (host.load throws).
        if !disabledFeatures.contains("search-and-destroy") {
            await loadSearchAndDestroyHost()
        }
        // ARM (don't load yet) this world's enabled library plugins + the bundled
        // leveldb. ALL MUSHclient plugin initialisation is deferred until the
        // character is in-game (first char.status state ≥ 3, after the MOTD), so
        // plugins don't run their init-time server probes (slist, cp info, …)
        // during login where those commands fail (D-74). Each plugin lives in its
        // own discoverable dir under ~/Documents/Proteles/Plugins/ (D-59), with
        // per-character data under <plugin>/data/<profile>/. dinv (D-32) keeps its
        // own arming; the session activates all three on the in-game signal.
        var pluginDirectories: [URL] = []
        if let libraryURL = try? PluginLibraryStore.defaultStoreURL() {
            let library = PluginLibraryStore(url: libraryURL)
            try? await library.load()
            pluginDirectories = await library.enabled(forProfile: id).compactMap { try? $0.directory() }
        }
        let dinvData = disabledFeatures.contains("dinv")
            ? nil : try? ProtelesPaths.pluginDataDirectory(named: "dinv", character: character)
        if let dinvData {
            await session.armBundledDinv(stateDirectory: dinvData.path)
        }
        let levelDBHome = disabledFeatures.contains("leveldb")
            ? nil : try? ProtelesPaths.pluginDirectory(named: "leveldb")
        await session.armInitialPlugins(
            directories: pluginDirectories,
            character: character,
            levelDBDirectory: levelDBHome?.path
        )
    }

    /// Toggle whether a script kind is shared across characters (the editor's
    /// per-tab "Shared" switch). The active set is unchanged — only where it's
    /// stored — so no reload is needed.
    public func setScriptGlobal(_ kind: ScriptScope.Kind, _ value: Bool) async {
        guard let store else { return }
        try? await store.setGlobal(kind, value)
        scriptScope = await store.scope
    }

    /// A readable, filesystem-safe per-character data-dir key for `id`: the
    /// profile's autologin username (the character), else its display name, else
    /// the UUID — so data lives under `…/data/<character>/`, never an opaque id.
    public static func characterKey(forProfile id: UUID) async -> String {
        guard let url = try? ProfileStore.defaultStoreURL() else { return id.uuidString }
        let store = ProfileStore(url: url)
        try? await store.load()
        let profile = await store.profiles.first { $0.id == id }
        let candidates = [profile?.autologin?.username, profile?.name]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return ProtelesPaths.directorySlug(for: trimmed) }
        }
        return id.uuidString
    }

    // MARK: - Search-and-Destroy (user-installed plugin)

    /// Build, load, and attach the S&D host, pointed at the global Databases/
    /// dir (where its SnDdb.db lives). No-op-ish when S&D isn't installed (load
    /// throws; the host just isn't attached).
    private func loadSearchAndDestroyHost() async {
        guard let databases = try? ProtelesPaths.databasesDirectory(),
              let host = try? SearchAndDestroyHost() else { return }
        await host.configure(directory: databases.path)
        // Persisted variables must land BEFORE load() — S&D reads GetVariable
        // at script top-level (the xset flags, area ranges) — #52.
        await session.hydrateSearchAndDestroyVariables(host)
        try? await host.load()
        await session.attachSearchAndDestroy(host)
    }

    /// Download + install the Search-and-Destroy plugin, then attach it live
    /// (no reconnect). Throws on download/extract failure. macOS only.
    public func installSearchAndDestroy() async throws {
        #if os(macOS)
            try await SearchAndDestroyInstaller.install()
            await loadSearchAndDestroyHost()
        #endif
    }

    // MARK: - Triggers

    public func addTrigger() async {
        let new = Trigger(pattern: .substring(""))
        try? await store?.addTrigger(new)
        await refresh()
        selectedTriggerID = new.id
        try? await session.scriptEngine?.addTrigger(new)
    }

    public func removeSelectedTrigger() async {
        guard let id = selectedTriggerID else { return }
        try? await store?.removeTrigger(id: id)
        await refresh()
        selectedTriggerID = triggers.first?.id
        await session.scriptEngine?.removeTrigger(id: id)
    }

    public func duplicateTrigger(id: UUID) async {
        guard let original = triggers.first(where: { $0.id == id }) else { return }
        let copy = original.duplicated()
        try? await store?.addTrigger(copy)
        await refresh()
        selectedTriggerID = copy.id
        try? await session.scriptEngine?.addTrigger(copy)
    }

    public func binding(forTrigger id: UUID) -> Binding<Trigger>? {
        guard triggers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.triggers.first { $0.id == id } ?? Trigger(pattern: .substring(""))
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = triggers.firstIndex(where: { $0.id == id }) {
                    triggers[index] = newValue
                }
                Task {
                    try? await self.store?.updateTrigger(newValue)
                    await self.session.scriptEngine?.updateTrigger(newValue)
                }
            }
        )
    }

    // MARK: - Aliases

    public func addAlias() async {
        let new = Alias(pattern: .exact(""))
        try? await store?.addAlias(new)
        await refresh()
        selectedAliasID = new.id
        try? await session.scriptEngine?.addAlias(new)
    }

    public func removeSelectedAlias() async {
        guard let id = selectedAliasID else { return }
        try? await store?.removeAlias(id: id)
        await refresh()
        selectedAliasID = aliases.first?.id
        await session.scriptEngine?.removeAlias(id: id)
    }

    public func duplicateAlias(id: UUID) async {
        guard let original = aliases.first(where: { $0.id == id }) else { return }
        let copy = original.duplicated()
        try? await store?.addAlias(copy)
        await refresh()
        selectedAliasID = copy.id
        try? await session.scriptEngine?.addAlias(copy)
    }

    public func binding(forAlias id: UUID) -> Binding<Alias>? {
        guard aliases.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.aliases.first { $0.id == id } ?? Alias(pattern: .exact(""))
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = aliases.firstIndex(where: { $0.id == id }) {
                    aliases[index] = newValue
                }
                Task {
                    try? await self.store?.updateAlias(newValue)
                    await self.session.scriptEngine?.updateAlias(newValue)
                }
            }
        )
    }

    // MARK: - Timers

    public func addTimer() async {
        let new = MudTimer(schedule: .every(60), action: .send(""))
        try? await store?.addTimer(new)
        await refresh()
        selectedTimerID = new.id
        _ = try? await session.addTimer(new)
    }

    public func removeSelectedTimer() async {
        guard let id = selectedTimerID else { return }
        try? await store?.removeTimer(id: id)
        await refresh()
        selectedTimerID = timers.first?.id
        await session.removeTimer(id: id)
    }

    public func duplicateTimer(id: UUID) async {
        guard let original = timers.first(where: { $0.id == id }) else { return }
        let copy = original.duplicated()
        try? await store?.addTimer(copy)
        await refresh()
        selectedTimerID = copy.id
        _ = try? await session.addTimer(copy)
    }

    public func binding(forTimer id: UUID) -> Binding<MudTimer>? {
        guard timers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.timers.first { $0.id == id }
                    ?? MudTimer(schedule: .every(60), action: .send(""))
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = timers.firstIndex(where: { $0.id == id }) {
                    timers[index] = newValue
                }
                Task {
                    try? await self.store?.updateTimer(newValue)
                    await self.session.updateTimer(newValue)
                }
            }
        )
    }

    // MARK: - Macros

    /// The action a keypress should fire, or `nil` if no macro is bound or its
    /// tier forbids firing right now. Synchronous (main-actor) so the command
    /// field's key monitor can decide inline whether to swallow the key.
    public func matchMacro(_ chord: KeyChord, context: MacroContext) -> MacroAction? {
        macroEngine.match(chord, context: context)?.action
    }

    public func addMacro() async {
        let new = Macro(chord: KeyChord(keyCode: 0), action: .command(""))
        try? await store?.addMacro(new)
        await refresh()
        selectedMacroID = new.id
    }

    public func removeSelectedMacro() async {
        guard let id = selectedMacroID else { return }
        try? await store?.removeMacro(id: id)
        await refresh()
        selectedMacroID = macros.first?.id
    }

    public func duplicateMacro(id: UUID) async {
        guard let original = macros.first(where: { $0.id == id }) else { return }
        let copy = original.duplicated()
        try? await store?.addMacro(copy)
        await refresh()
        selectedMacroID = copy.id
    }

    public func binding(forMacro id: UUID) -> Binding<Macro>? {
        guard macros.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in
                self?.macros.first { $0.id == id }
                    ?? Macro(chord: KeyChord(keyCode: 0), action: .command(""))
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = macros.firstIndex(where: { $0.id == id }) {
                    macros[index] = newValue
                    syncMacroEngine()
                }
                Task { try? await self.store?.updateMacro(newValue) }
            }
        )
    }

    // MARK: - Private

    /// Open (or create) the per-world map store and load its graph. The DB
    /// lives in the global `~/Documents/Proteles/Databases/Aardwolf.db` — one
    /// map of Aardwolf shared across characters (D-59).
    private static func makeMapper() -> Mapper? {
        guard let url = try? ProtelesPaths.mapperDatabaseURL(),
              let store = try? MapperStore(url: url)
        else { return nil }
        return try? Mapper(store: store)
    }

    func refresh() async {
        guard let store else { return }
        let document = await store.document
        triggers = document.triggers
        aliases = document.aliases
        timers = document.timers
        macros = document.macros
        buttonBar = document.buttonBar
        keypad = document.keypad
        syncMacroEngine()
    }

    /// Rebuild the live macro lookup from the user's stored macros + the
    /// transient plugin-registered accelerators.
    private func syncMacroEngine() {
        macroEngine.replaceAll(macros + pluginMacros)
    }

    /// Register a plugin's `Accelerator`/`AcceleratorTo` keybind into the live
    /// engine (transient). Replaces any existing binding on the same chord, so
    /// the last registration wins (matching MUSHclient's AcceleratorTo).
    public func addPluginMacro(_ macro: Macro) {
        pluginMacros.removeAll { $0.chord == macro.chord }
        pluginMacros.append(macro)
        syncMacroEngine()
    }
}
