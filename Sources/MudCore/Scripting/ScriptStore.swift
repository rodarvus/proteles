import Foundation

/// The persisted scripting set for one world: its triggers, aliases, timers, and
/// macros (PLAN.md §8.6). Loaded into a ``ScriptEngine`` at connect time.
public struct ScriptDocument: Codable, Sendable, Equatable {
    public var triggers: [Trigger]
    public var aliases: [Alias]
    public var timers: [MudTimer]
    public var macros: [Macro]
    /// The command-button bar (GH #15).
    public var buttonBar: ButtonBar

    public init(
        triggers: [Trigger] = [],
        aliases: [Alias] = [],
        timers: [MudTimer] = [],
        macros: [Macro] = [],
        buttonBar: ButtonBar = ButtonBar()
    ) {
        self.triggers = triggers
        self.aliases = aliases
        self.timers = timers
        self.macros = macros
        self.buttonBar = buttonBar
    }

    private enum CodingKeys: String, CodingKey {
        case triggers, aliases, timers, macros, buttonBar
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
        buttonBar = try container.decodeIfPresent(ButtonBar.self, forKey: .buttonBar) ?? ButtonBar()
    }
}

/// Which script kinds are **shared across characters** (global) vs per-character.
/// Persisted at `Scripts/scope.json`. Default: everything per-character.
public struct ScriptScope: Codable, Sendable, Equatable {
    public var triggers = false
    public var aliases = false
    public var timers = false
    public var macros = false

    public init() {}

    public enum Kind: String, CaseIterable, Sendable {
        case triggers, aliases, timers, macros
    }

    public func isGlobal(_ kind: Kind) -> Bool {
        switch kind {
        case .triggers: triggers
        case .aliases: aliases
        case .timers: timers
        case .macros: macros
        }
    }

    public mutating func setGlobal(_ kind: Kind, _ value: Bool) {
        switch kind {
        case .triggers: triggers = value
        case .aliases: aliases = value
        case .timers: timers = value
        case .macros: macros = value
        }
    }
}

/// Actor that owns a world's user-defined automations and persists them under
/// `~/Documents/Proteles/Scripts/`, **split by kind** into discoverable,
/// hand-editable JSON files. Each kind is independently per-character
/// (`Scripts/<character>/triggers.json`) or shared across characters
/// (`Scripts/_shared/triggers.json`), controlled by ``ScriptScope``.
///
/// Storage only — it holds no live engine. The app loads the document at connect
/// time into a ``ScriptEngine`` and writes user edits back here. Transient,
/// script-created automations are runtime-only and never stored.
public actor ScriptStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
        case notFound(UUID)
    }

    /// The Scripts home (`~/Documents/Proteles/Scripts/`).
    public let directory: URL
    /// The character key for the per-character subdirectory.
    public let character: String
    /// The shared subdirectory name (kinds toggled global live here).
    private static let sharedDir = "_shared"
    private static let scopeFile = "scope.json"

    public private(set) var scope: ScriptScope
    public private(set) var triggers: [Trigger] = []
    public private(set) var aliases: [Alias] = []
    public private(set) var timers: [MudTimer] = []
    public private(set) var macros: [Macro] = []

    public init(directory: URL, character: String) {
        self.directory = directory
        self.character = character
        scope = Self.readScope(directory)
    }

    /// A snapshot of the current document (for loading into an engine).
    public var document: ScriptDocument {
        ScriptDocument(triggers: triggers, aliases: aliases, timers: timers, macros: macros)
    }

    // MARK: - Load

    /// Load every kind from its scoped file. Missing files are empty sets (a
    /// fresh setup doesn't litter empty files until the first edit).
    public func load() throws {
        scope = Self.readScope(directory)
        triggers = decode([Trigger].self, .triggers)
        aliases = decode([Alias].self, .aliases)
        timers = decode([MudTimer].self, .timers)
        macros = decode([Macro].self, .macros)
    }

    /// Replace the whole document at once (e.g. an import) and persist each kind.
    public func replace(with document: ScriptDocument) throws {
        triggers = document.triggers
        aliases = document.aliases
        timers = document.timers
        macros = document.macros
        for kind in ScriptScope.Kind.allCases {
            try persist(kind)
        }
    }

    /// Toggle whether a kind is shared across characters. The current set moves
    /// with you (it's written to the new scoped location); the old file is left
    /// in place so toggling back restores the character's previous set.
    public func setGlobal(_ kind: ScriptScope.Kind, _ value: Bool) throws {
        scope.setGlobal(kind, value)
        try persist(kind)
        try writeScope()
    }

    // MARK: - Triggers

    public func addTrigger(_ trigger: Trigger) throws {
        triggers.append(trigger)
        try persist(.triggers)
    }

    public func updateTrigger(_ trigger: Trigger) throws {
        guard let index = triggers.firstIndex(where: { $0.id == trigger.id }) else {
            throw StoreError.notFound(trigger.id)
        }
        triggers[index] = trigger
        try persist(.triggers)
    }

    public func removeTrigger(id: UUID) throws {
        guard triggers.contains(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        triggers.removeAll { $0.id == id }
        try persist(.triggers)
    }

    // MARK: - Aliases

    public func addAlias(_ alias: Alias) throws {
        aliases.append(alias)
        try persist(.aliases)
    }

    public func updateAlias(_ alias: Alias) throws {
        guard let index = aliases.firstIndex(where: { $0.id == alias.id }) else {
            throw StoreError.notFound(alias.id)
        }
        aliases[index] = alias
        try persist(.aliases)
    }

    public func removeAlias(id: UUID) throws {
        guard aliases.contains(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        aliases.removeAll { $0.id == id }
        try persist(.aliases)
    }

    // MARK: - Timers

    public func addTimer(_ timer: MudTimer) throws {
        timers.append(timer)
        try persist(.timers)
    }

    public func updateTimer(_ timer: MudTimer) throws {
        guard let index = timers.firstIndex(where: { $0.id == timer.id }) else {
            throw StoreError.notFound(timer.id)
        }
        timers[index] = timer
        try persist(.timers)
    }

    public func removeTimer(id: UUID) throws {
        guard timers.contains(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        timers.removeAll { $0.id == id }
        try persist(.timers)
    }

    // MARK: - Macros

    public func addMacro(_ macro: Macro) throws {
        macros.append(macro)
        try persist(.macros)
    }

    public func updateMacro(_ macro: Macro) throws {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else {
            throw StoreError.notFound(macro.id)
        }
        macros[index] = macro
        try persist(.macros)
    }

    public func removeMacro(id: UUID) throws {
        guard macros.contains(where: { $0.id == id }) else { throw StoreError.notFound(id) }
        macros.removeAll { $0.id == id }
        try persist(.macros)
    }

    // MARK: - Disk

    /// The directory a kind lives in: `Scripts/<character>/` or, if shared,
    /// `Scripts/_shared/`. Created on demand.
    private func scopedDirectory(for kind: ScriptScope.Kind) -> URL {
        let sub = scope.isGlobal(kind) ? Self.sharedDir : character
        let url = directory.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func path(for kind: ScriptScope.Kind) -> URL {
        scopedDirectory(for: kind).appendingPathComponent("\(kind.rawValue).json")
    }

    private func decode<T: Decodable>(_: [T].Type, _ kind: ScriptScope.Kind) -> [T] {
        guard let data = FileManager.default.contents(atPath: path(for: kind).path) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func persist(_ kind: ScriptScope.Kind) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = switch kind {
            case .triggers: try encoder.encode(triggers)
            case .aliases: try encoder.encode(aliases)
            case .timers: try encoder.encode(timers)
            case .macros: try encoder.encode(macros)
            }
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
        do {
            try data.write(to: path(for: kind), options: .atomic)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Scope persistence

    private static func readScope(_ directory: URL) -> ScriptScope {
        let url = directory.appendingPathComponent(scopeFile)
        guard let data = FileManager.default.contents(atPath: url.path),
              let scope = try? JSONDecoder().decode(ScriptScope.self, from: data)
        else { return ScriptScope() }
        return scope
    }

    private func writeScope() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(scope).write(
                to: directory.appendingPathComponent(Self.scopeFile),
                options: .atomic
            )
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }
}
