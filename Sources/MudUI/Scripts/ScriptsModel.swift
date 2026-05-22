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
                    await self.session.scriptEngine?.removeTrigger(id: id)
                    try? await self.session.scriptEngine?.addTrigger(newValue)
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
                    await self.session.scriptEngine?.removeAlias(id: id)
                    try? await self.session.scriptEngine?.addAlias(newValue)
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
                    await self.session.removeTimer(id: id)
                    _ = try? await self.session.addTimer(newValue)
                }
            }
        )
    }

    // MARK: - Private

    private func refresh() async {
        guard let store else { return }
        let document = await store.document
        triggers = document.triggers
        aliases = document.aliases
        timers = document.timers
    }
}
