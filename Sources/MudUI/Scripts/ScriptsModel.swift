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

    public var selectedTriggerID: UUID?
    public var selectedAliasID: UUID?
    public var selectedTimerID: UUID?
    public var selectedMacroID: UUID?
    /// Which script kinds are shared across characters (for the editor toggles).
    public private(set) var scriptScope = ScriptScope()

    private let session: SessionController
    private var store: ScriptStore?
    private var profileID: UUID?
    /// Live keypress→action lookup, kept in sync with ``macros``. Held here
    /// (main-actor, value type) so the command field's key monitor can match
    /// a chord inline; the session has no macro engine of its own.
    private var macroEngine = MacroEngine()

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
        scriptScope = await store.scope
        await seedDefaultMacrosIfNeeded(store: store, profileID: id)
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
        // Attach the live map, backed by the global Databases/Aardwolf.db.
        if let mapper = Self.makeMapper() {
            await session.attachMapper(mapper)
        }
        // Attach the native Search-and-Destroy host (if installed): its own
        // sandboxed runtime, pointed at the global Databases/ dir (its
        // SnDdb.db). Inert when S&D isn't installed (host.load throws).
        await loadSearchAndDestroyHost()
        // Then load this world's enabled library plugins (after the script reset
        // above, so their triggers/timers survive). Each lives in its own
        // discoverable dir under ~/Documents/Proteles/Plugins/ (see D-59), with
        // its per-character data under <plugin>/data/<profile>/.
        if let libraryURL = try? PluginLibraryStore.defaultStoreURL() {
            let library = PluginLibraryStore(url: libraryURL)
            try? await library.load()
            let directories = await library.enabled(forProfile: id).compactMap { try? $0.directory() }
            await session.loadPlugins(directories: directories, character: character)
        }
        // dinv (D-32): its per-character DB lives under Plugins/dinv/data/<character>/.
        // Armed here; loaded once the character is active.
        if let dinvData = try? ProtelesPaths.pluginDataDirectory(named: "dinv", character: character) {
            await session.armBundledDinv(stateDirectory: dinvData.path)
        }
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
    static func characterKey(forProfile id: UUID) async -> String {
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

    /// Replace all macros with the built-in keypad layout (a "Restore
    /// defaults" action). Overwrites the user's current set.
    public func restoreDefaultMacros() async {
        guard let store else { return }
        var document = await store.document
        document.macros = MacroEngine.defaultNavigationMacros()
        try? await store.replace(with: document)
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
                    macroEngine.replaceAll(macros)
                }
                Task { try? await self.store?.updateMacro(newValue) }
            }
        )
    }

    /// On a profile's first load, seed the built-in keypad layout — once per
    /// profile (deleting them won't re-seed). Existing profiles created before
    /// this feature get the defaults on their next load.
    private func seedDefaultMacrosIfNeeded(store: ScriptStore, profileID: UUID) async {
        let key = "com.proteles.macrosSeeded.\(profileID.uuidString)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var document = await store.document
        if document.macros.isEmpty {
            document.macros = MacroEngine.defaultNavigationMacros()
            try? await store.replace(with: document)
        }
        UserDefaults.standard.set(true, forKey: key)
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

    private func refresh() async {
        guard let store else { return }
        let document = await store.document
        triggers = document.triggers
        aliases = document.aliases
        timers = document.timers
        macros = document.macros
        macroEngine.replaceAll(document.macros)
    }
}
