import Foundation
import MudCore
import Observation

/// A MUSHclient plugin installed for a world: the on-disk `.xml` plus parsed
/// metadata for display.
public struct InstalledPlugin: Identifiable, Sendable, Equatable {
    /// The file URL (also the stable identity).
    public let id: URL
    public let name: String
    public let author: String
    public let version: String
    /// `false` if the file couldn't be parsed as a plugin.
    public let parsed: Bool

    public var fileName: String {
        id.lastPathComponent
    }
}

/// A built-in native (Swift) plugin shown in the Plugins window, with its
/// live enabled state and displayable help.
public struct NativePluginRow: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let author: String
    public let version: String
    public let summary: String
    public let help: NativePluginHelp
    public var enabled: Bool
}

/// What's selected in the Plugins window: a built-in native plugin (by id)
/// or an imported `.xml` plugin (by file URL).
public enum PluginSelection: Hashable, Sendable {
    case native(String)
    case imported(URL)
}

/// `@Observable` model for the Plugins window: lists a world's installed
/// `.xml` plugins and the built-in native plugins, imports new ones (with a
/// compatibility report), and removes/toggles them. File operations live
/// here; re-syncing the live session is delegated to a `resync` closure the
/// app supplies (so a change applies immediately).
@MainActor
@Observable
public final class PluginsModel {
    public private(set) var installed: [InstalledPlugin] = []
    /// Built-in native plugins registered on the session's engine.
    public private(set) var nativePlugins: [NativePluginRow] = []
    public var selection: PluginSelection?

    private let session: SessionController
    private var directory: URL?
    private var resync: (@MainActor () async -> Void)?

    public init(session: SessionController) {
        self.session = session
    }

    /// The selected imported plugin's file URL, if an imported plugin (not a
    /// native one) is selected — used by the import/remove flow.
    public var selectedImportedURL: URL? {
        if case .imported(let url) = selection { return url }
        return nil
    }

    /// The selected built-in native plugin, if one is selected.
    public var selectedNative: NativePluginRow? {
        guard case .native(let id) = selection else { return nil }
        return nativePlugins.first { $0.id == id }
    }

    /// Load the built-in native plugins' current enabled state from the
    /// engine. Call when the Plugins window appears.
    public func refreshNative() async {
        let listing = await session.scriptEngine?.nativePluginListing() ?? []
        nativePlugins = listing.map {
            NativePluginRow(
                id: $0.metadata.id,
                name: $0.metadata.name,
                author: $0.metadata.author,
                version: $0.metadata.version,
                summary: $0.metadata.summary,
                help: $0.help,
                enabled: $0.enabled
            )
        }
    }

    /// Enable/disable a native plugin by id; applies live to the session.
    public func setNativeEnabled(_ enabled: Bool, id: String) async {
        _ = await session.scriptEngine?.setNativePluginEnabled(enabled, id: id)
        await refreshNative()
    }

    /// Point the model at a world's plugins directory and supply the
    /// re-sync action (typically reloading the active profile's scripts +
    /// plugins). Call when the Plugins window appears.
    public func prepare(directory: URL, resync: @escaping @MainActor () async -> Void) {
        self.directory = directory
        self.resync = resync
        refresh()
    }

    /// Re-scan the directory for `.xml` plugins.
    public func refresh() {
        guard let directory else { installed = []; return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        installed = urls
            .filter { $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Self.describe)
    }

    /// Parse + analyse a candidate file for the import preview. `nil` if it
    /// isn't a parseable plugin.
    public func report(for url: URL) -> PluginImportReport? {
        guard let data = try? Data(contentsOf: url),
              let plugin = try? MUSHclientPluginLoader.parse(data)
        else { return nil }
        return PluginImporter.analyze(plugin)
    }

    /// Copy `sourceURL` into the world's plugins directory and re-sync the
    /// live session so it loads immediately. Returns the installed entry's id.
    @discardableResult
    public func install(from sourceURL: URL) async -> URL? {
        guard let directory else { return nil }
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            return nil
        }
        refresh()
        await resync?()
        return destination
    }

    /// Delete an installed plugin's file and re-sync.
    public func remove(_ plugin: InstalledPlugin) async {
        try? FileManager.default.removeItem(at: plugin.id)
        if selection == .imported(plugin.id) { selection = nil }
        refresh()
        await resync?()
    }

    // MARK: - Private

    private static func describe(_ url: URL) -> InstalledPlugin {
        guard let data = try? Data(contentsOf: url),
              let plugin = try? MUSHclientPluginLoader.parse(data)
        else {
            return InstalledPlugin(
                id: url, name: url.lastPathComponent, author: "", version: "", parsed: false
            )
        }
        return InstalledPlugin(
            id: url,
            name: plugin.name.isEmpty ? url.lastPathComponent : plugin.name,
            author: plugin.author,
            version: plugin.version,
            parsed: true
        )
    }
}
