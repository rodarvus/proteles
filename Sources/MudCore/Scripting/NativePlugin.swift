import Foundation

/// Identity and display metadata for a ``NativePlugin``.
///
/// `id` is the stable handle other plugins target with `CallPlugin(id, …)`
/// and the key the host toggles enable/disable on; the rest is for the
/// Plugins window.
public struct NativePluginMetadata: Sendable, Equatable {
    public let id: String
    public let name: String
    public let author: String
    public let version: String
    public let summary: String

    public init(
        id: String,
        name: String,
        author: String = "Proteles",
        version: String = "1.0",
        summary: String = ""
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.summary = summary
    }
}

/// A self-contained, *native* (Swift) Proteles plugin: a value-type reducer
/// that participates in the same effect pipeline as Lua plugins (PLAN.md
/// §7.6). It owns commands, reacts to incoming lines and GMCP, and exposes
/// callable entry points for other plugins — but, like the trigger/alias/
/// timer engines, it only *decides* (returns ``ScriptEffect``s); the host
/// applies them. That keeps each plugin unit-testable without UI, network,
/// or Lua.
///
/// Every hook has a default, so a plugin implements only what it needs (a
/// command-only plugin overrides just ``handleCommand(_:)``). Plugins are
/// held by a ``NativePluginRegistry`` inside ``ScriptEngine`` and can be
/// enabled/disabled and listed in the Plugins window alongside imported
/// `.xml` plugins.
public protocol NativePlugin: Sendable {
    /// Stable identity + display metadata.
    var metadata: NativePluginMetadata { get }

    /// One-time setup (≈ MUSHclient `OnPluginInstall`), run when the plugin
    /// is registered or re-enabled. Default: no effects.
    mutating func install() -> [ScriptEffect]

    /// Handle a typed command. Return `nil` to leave the input unhandled
    /// (it is sent to the MUD as usual); return an effect list — possibly
    /// empty — to *consume* the input (it is NOT sent) and apply those
    /// effects. Default: unhandled.
    mutating func handleCommand(_ input: String) -> [ScriptEffect]?

    /// React to an incoming line: a gag decision plus effects, like a
    /// trigger. Default: pass through (no gag, no effects).
    mutating func onLine(_ text: String) -> ScriptEngine.LineDisposition

    /// React to a GMCP package update (`package` is the lowercased name,
    /// `json` its decoded payload). Default: no effects.
    mutating func onGMCP(package: String, json: String) -> [ScriptEffect]

    /// Synchronous callable entry points for `CallPlugin(id, fn, …)` from
    /// other plugins (the "usable by other plugins" surface). Default: none.
    func call(_ function: String, _ arguments: [LuaValue]) -> [LuaValue]
}

public extension NativePlugin {
    mutating func install() -> [ScriptEffect] {
        []
    }

    mutating func handleCommand(_: String) -> [ScriptEffect]? {
        nil
    }

    mutating func onLine(_: String) -> ScriptEngine.LineDisposition {
        .init()
    }

    mutating func onGMCP(package _: String, json _: String) -> [ScriptEffect] {
        []
    }

    func call(_: String, _: [LuaValue]) -> [LuaValue] {
        []
    }
}

/// Holds the registered native plugins and folds session events across the
/// enabled ones (commands, lines, GMCP, calls). A value type owned by
/// ``ScriptEngine``; registration, enable/disable, and listing are pure
/// mutations, so the whole host is testable in isolation.
public struct NativePluginRegistry: Sendable {
    private struct Entry {
        var plugin: any NativePlugin
        var enabled: Bool
    }

    private var entries: [Entry] = []

    public init() {}

    /// Register a plugin. When `enabled`, its ``NativePlugin/install()``
    /// effects are returned so the host can apply them.
    @discardableResult
    public mutating func register(_ plugin: any NativePlugin, enabled: Bool = true) -> [ScriptEffect] {
        var plugin = plugin
        let effects = enabled ? plugin.install() : []
        entries.append(Entry(plugin: plugin, enabled: enabled))
        return effects
    }

    /// Enable/disable a plugin by id. Re-enabling re-runs `install()`.
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, id: String) -> [ScriptEffect] {
        guard let index = entries.firstIndex(where: { $0.plugin.metadata.id == id }) else { return [] }
        let wasEnabled = entries[index].enabled
        entries[index].enabled = enabled
        return (enabled && !wasEnabled) ? entries[index].plugin.install() : []
    }

    /// The registered plugins' metadata + current enabled state, in
    /// registration order (drives the Plugins window listing).
    public var listing: [(metadata: NativePluginMetadata, enabled: Bool)] {
        entries.map { ($0.plugin.metadata, $0.enabled) }
    }

    /// Offer a typed command to each enabled plugin in order; the first to
    /// claim it wins. `nil` means no plugin handled it (send verbatim).
    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        for index in entries.indices where entries[index].enabled {
            if let effects = entries[index].plugin.handleCommand(input) { return effects }
        }
        return nil
    }

    /// Fold an incoming line through every enabled plugin, OR-ing gags and
    /// concatenating effects in registration order.
    public mutating func onLine(_ text: String) -> ScriptEngine.LineDisposition {
        var disposition = ScriptEngine.LineDisposition()
        for index in entries.indices where entries[index].enabled {
            let result = entries[index].plugin.onLine(text)
            if result.gag { disposition.gag = true }
            disposition.effects.append(contentsOf: result.effects)
        }
        return disposition
    }

    /// Fan a GMCP update to every enabled plugin, concatenating effects.
    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        var effects: [ScriptEffect] = []
        for index in entries.indices where entries[index].enabled {
            effects.append(contentsOf: entries[index].plugin.onGMCP(package: package, json: json))
        }
        return effects
    }

    /// Route a `CallPlugin`-style call to an enabled plugin by id. Returns
    /// an empty result for an unknown/disabled id or unknown function.
    public func call(id: String, function: String, arguments: [LuaValue]) -> [LuaValue] {
        guard let entry = entries.first(where: { $0.plugin.metadata.id == id && $0.enabled }) else {
            return []
        }
        return entry.plugin.call(function, arguments)
    }
}
