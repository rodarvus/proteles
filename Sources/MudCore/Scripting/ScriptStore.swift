import Foundation

/// The persisted scripting set for one world: its triggers, aliases, and
/// timers (PLAN.md §8.6). One JSON document per profile, mirroring
/// ``ProfileDocument``.
public struct ScriptDocument: Codable, Sendable, Equatable {
    public var triggers: [Trigger]
    public var aliases: [Alias]
    public var timers: [MudTimer]
    public var macros: [Macro]

    public init(
        triggers: [Trigger] = [],
        aliases: [Alias] = [],
        timers: [MudTimer] = [],
        macros: [Macro] = []
    ) {
        self.triggers = triggers
        self.aliases = aliases
        self.timers = timers
        self.macros = macros
    }

    private enum CodingKeys: String, CodingKey {
        case triggers, aliases, timers, macros
    }

    /// A collection missing from the file decodes as empty rather than failing
    /// the whole load, so documents written before a collection existed (e.g.
    /// a pre-macros script file) still open. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        triggers = try container.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        aliases = try container.decodeIfPresent([Alias].self, forKey: .aliases) ?? []
        timers = try container.decodeIfPresent([MudTimer].self, forKey: .timers) ?? []
        macros = try container.decodeIfPresent([Macro].self, forKey: .macros) ?? []
    }
}

/// Actor that owns a world's user-defined automations and persists them to
/// disk, mirroring ``ProfileStore``: the whole document is rewritten
/// atomically after each change (these sets are small and edited rarely).
///
/// Storage only — it holds no live ``TriggerEngine``/``AliasEngine``/
/// ``TimerEngine``. The app loads the document at connect time and feeds it
/// into a ``ScriptEngine``, and writes user edits back here. Transient,
/// script-created automations (one-shot triggers, Mudlet-style temporary
/// timers) are runtime-only and never added to the store.
public actor ScriptStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
        case notFound(UUID)
    }

    /// On-disk path of this world's script document.
    public let url: URL

    public private(set) var triggers: [Trigger] = []
    public private(set) var aliases: [Alias] = []
    public private(set) var timers: [MudTimer] = []
    public private(set) var macros: [Macro] = []

    public init(url: URL) {
        self.url = url
    }

    /// A snapshot of the current document (for loading into a engine).
    public var document: ScriptDocument {
        ScriptDocument(triggers: triggers, aliases: aliases, timers: timers, macros: macros)
    }

    // MARK: - Load

    /// Load the document from disk. A missing file is treated as an empty
    /// set (nothing is written until the first edit), so fresh profiles
    /// don't litter empty files.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            apply(ScriptDocument())
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
        do {
            try apply(JSONDecoder().decode(ScriptDocument.self, from: data))
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
    }

    /// Replace the whole document at once (e.g. an import).
    public func replace(with document: ScriptDocument) throws {
        apply(document)
        try persist()
    }

    // MARK: - Triggers

    public func addTrigger(_ trigger: Trigger) throws {
        triggers.append(trigger)
        try persist()
    }

    public func updateTrigger(_ trigger: Trigger) throws {
        guard let index = triggers.firstIndex(where: { $0.id == trigger.id }) else {
            throw StoreError.notFound(trigger.id)
        }
        triggers[index] = trigger
        try persist()
    }

    public func removeTrigger(id: UUID) throws {
        guard triggers.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        triggers.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Aliases

    public func addAlias(_ alias: Alias) throws {
        aliases.append(alias)
        try persist()
    }

    public func updateAlias(_ alias: Alias) throws {
        guard let index = aliases.firstIndex(where: { $0.id == alias.id }) else {
            throw StoreError.notFound(alias.id)
        }
        aliases[index] = alias
        try persist()
    }

    public func removeAlias(id: UUID) throws {
        guard aliases.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        aliases.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Timers

    public func addTimer(_ timer: MudTimer) throws {
        timers.append(timer)
        try persist()
    }

    public func updateTimer(_ timer: MudTimer) throws {
        guard let index = timers.firstIndex(where: { $0.id == timer.id }) else {
            throw StoreError.notFound(timer.id)
        }
        timers[index] = timer
        try persist()
    }

    public func removeTimer(id: UUID) throws {
        guard timers.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        timers.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Macros

    public func addMacro(_ macro: Macro) throws {
        macros.append(macro)
        try persist()
    }

    public func updateMacro(_ macro: Macro) throws {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else {
            throw StoreError.notFound(macro.id)
        }
        macros[index] = macro
        try persist()
    }

    public func removeMacro(id: UUID) throws {
        guard macros.contains(where: { $0.id == id }) else {
            throw StoreError.notFound(id)
        }
        macros.removeAll { $0.id == id }
        try persist()
    }

    // MARK: - Disk

    /// Recommended per-profile location:
    /// `~/Library/Application Support/com.proteles.ProtelesApp/scripts/<id>.json`.
    /// Creates the parent directory if needed.
    public static func defaultStoreURL(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw StoreError.loadFailed("no Application Support directory")
        }
        let folder = support
            .appendingPathComponent("com.proteles.ProtelesApp", isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Private

    private func apply(_ document: ScriptDocument) {
        triggers = document.triggers
        aliases = document.aliases
        timers = document.timers
        macros = document.macros
    }

    private func persist() throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(document)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }
}
