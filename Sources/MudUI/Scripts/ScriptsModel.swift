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

    private let session: SessionController
    private var store: ScriptStore?
    private var profileID: UUID?
    /// Live keypress→action lookup, kept in sync with ``macros``. Held here
    /// (main-actor, value type) so the command field's key monitor can match
    /// a chord inline; the session has no macro engine of its own.
    private var macroEngine = MacroEngine()
    /// The active world's data dir, kept so Search-and-Destroy can be (re)loaded
    /// after a download-on-first-use install without reloading the whole world.
    private var worldDataDir: URL?

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
        guard let url = try? ScriptStore.defaultStoreURL(forProfile: id) else { return }
        let store = ScriptStore(url: url)
        try? await store.load()
        self.store = store
        profileID = id
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
        // The per-profile world-data dir: the lsqlite3 sandbox root + the
        // GetInfo(66) plugins use to find the mapper DB / keep their own DBs.
        // Attach it before loading the mapper + plugins.
        let worldDataDir = try? MapperStore.worldDataDirectory(forProfile: id)
        self.worldDataDir = worldDataDir
        if let worldDataDir {
            await session.attachWorldDataDirectory(worldDataDir.path)
        }
        // Attach the per-world live map (GMCP feeds it once connected).
        if let mapper = Self.makeMapper(forProfile: id) {
            await session.attachMapper(mapper)
        }
        // Attach the native Search-and-Destroy host (if S&D is installed): its
        // own sandboxed runtime + curated bindings, pointed at the world-data
        // dir. Inert when S&D isn't installed (host.load throws); the user can
        // install it on demand (see installSearchAndDestroy()).
        if let worldDataDir {
            await loadSearchAndDestroyHost(worldDataDir: worldDataDir)
        }
        // Then load this world's MUSHclient .xml plugins (after the script
        // reset above, so their triggers/timers survive).
        if let pluginsDirectory = MUSHclientPluginLoader.defaultDirectory(forProfile: id) {
            await session.loadPlugins(fromDirectory: pluginsDirectory)
        }
        // Then this world's personal plugins, referenced in place from the
        // user's own disk (never copied here); modules resolve from their folder.
        if let localURL = try? LocalPluginStore.defaultStoreURL(forProfile: id) {
            let localStore = LocalPluginStore(url: localURL)
            try? await localStore.load()
            await session.loadLocalPlugins(localStore.plugins)
        }
        // dinv (D-32): its per-character DB lives under the world-data dir (the
        // sqlite root). Armed here; loaded once the character is active (D-32).
        // The `aard_GMCP_handler` blocker is resolved (D-33); the [dinv-DBG]
        // trace stays installed until dinv is verified solid end-to-end.
        if let worldDataDir {
            await session.armBundledDinv(stateDirectory: worldDataDir.path)
        }
    }

    // MARK: - Search-and-Destroy (user-installed plugin)

    /// Build, load, and attach the S&D host for `worldDataDir`. No-op-ish when
    /// S&D isn't installed (load throws; the host just isn't attached).
    private func loadSearchAndDestroyHost(worldDataDir: URL) async {
        guard let host = try? SearchAndDestroyHost() else { return }
        await host.configure(directory: worldDataDir.path)
        try? await host.load()
        await session.attachSearchAndDestroy(host)
    }

    /// Download + install the Search-and-Destroy plugin, then attach it live
    /// (no reconnect). Throws on download/extract failure. macOS only.
    public func installSearchAndDestroy() async throws {
        #if os(macOS)
            try await SearchAndDestroyInstaller.install()
            if let worldDataDir {
                await loadSearchAndDestroyHost(worldDataDir: worldDataDir)
            }
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
    /// lives in the world-data dir as `<WorldName>.db` (migrating any legacy
    /// `mapper/<id>.db`), so plugins find it at `GetInfo(66)..WorldName()..".db"`.
    private static func makeMapper(forProfile id: UUID) -> Mapper? {
        guard let url = try? MapperStore.worldDatabaseURL(forProfile: id, worldName: "Aardwolf"),
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
