import Foundation

/// Per-world persistence for the built-in native plugins: each plugin's
/// serialized state (e.g. a user's `#sub`/`#gag` rules) plus its
/// enabled/disabled flag. One JSON document per world, mirroring
/// ``VariableStore``/``ScriptStore`` — storage only; the live state lives in
/// the plugins held by ``ScriptEngine``.
public actor NativePluginStore {
    public enum StoreError: Error, Equatable {
        case loadFailed(String)
        case saveFailed(String)
    }

    /// The on-disk document. `state` values are each plugin's own JSON blob
    /// (base64-encoded by the JSON coder); `enabled` records user toggles.
    public struct Document: Codable, Sendable, Equatable {
        public var state: [String: Data]
        public var enabled: [String: Bool]

        public init(state: [String: Data] = [:], enabled: [String: Bool] = [:]) {
            self.state = state
            self.enabled = enabled
        }
    }

    public let url: URL
    public private(set) var document = Document()

    public init(url: URL) {
        self.url = url
    }

    /// Load from disk. A missing file is an empty document.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            document = Document()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw StoreError.loadFailed(error.localizedDescription)
        }
    }

    /// Upsert (or clear, when `data` is nil) a plugin's serialized state.
    public func setState(_ data: Data?, id: String) throws {
        document.state[id] = data
        try persist()
    }

    /// Record a plugin's enabled flag.
    public func setEnabled(_ enabled: Bool, id: String) throws {
        document.enabled[id] = enabled
        try persist()
    }

    // MARK: - Disk

    /// `~/Library/Application Support/com.proteles.ProtelesApp/native-plugins/<id>.json`.
    public static func defaultStoreURL(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw StoreError.loadFailed("no Application Support directory")
        }
        let folder = support
            .appendingPathComponent("com.proteles.ProtelesApp", isDirectory: true)
            .appendingPathComponent("native-plugins", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Private

    private func persist() throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }
}
