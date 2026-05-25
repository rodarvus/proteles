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

    public var selectedTriggerID: UUID?
    public var selectedAliasID: UUID?
    public var selectedTimerID: UUID?

    private let session: SessionController
    private var store: ScriptStore?
    private var profileID: UUID?

    public init(session: SessionController) {
        self.session = session
    }

    /// Load a profile's scripts: build its store, mirror the document, and
    /// install the whole set into the live session. Idempotent per profile.
    public func load(forProfile id: UUID) async {
        guard let url = try? ScriptStore.defaultStoreURL(forProfile: id) else { return }
        let store = ScriptStore(url: url)
        try? await store.load()
        self.store = store
        profileID = id
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
        if let worldDataDir {
            await session.attachWorldDataDirectory(worldDataDir.path)
        }
        // Attach the per-world live map (GMCP feeds it once connected).
        if let mapper = Self.makeMapper(forProfile: id) {
            await session.attachMapper(mapper)
        }
        // Attach the native Search-and-Destroy host: its own sandboxed runtime
        // + curated bindings, pointed at the same world-data dir (where it
        // finds the mapper DB and keeps its SnDdb.db). Its triggers/aliases/
        // timers then run live and it publishes its model to the S&D panel.
        if let worldDataDir, let host = try? SearchAndDestroyHost() {
            await host.configure(directory: worldDataDir.path)
            try? await host.load()
            await session.attachSearchAndDestroy(host)
        }
        // Then load this world's MUSHclient .xml plugins (after the script
        // reset above, so their triggers/timers survive).
        if let pluginsDirectory = MUSHclientPluginLoader.defaultDirectory(forProfile: id) {
            await session.loadPlugins(fromDirectory: pluginsDirectory)
        }
        // The vendored dinv inventory manager (verbatim via the compat shim);
        // its per-character DB lives under the world-data dir (the sqlite root).
        if let worldDataDir {
            await session.loadBundledDinv(stateDirectory: worldDataDir.path)
        }
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
    }
}
