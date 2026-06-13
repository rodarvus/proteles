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

/// Human-readable help for a ``NativePlugin``, shown in the Plugins window
/// when its row is selected: a short overview plus the commands it enables.
public struct NativePluginHelp: Sendable, Equatable {
    /// One command the plugin handles: its syntax and what it does.
    public struct Command: Sendable, Equatable, Identifiable {
        public let syntax: String
        public let summary: String
        public var id: String {
            syntax
        }

        public init(syntax: String, summary: String) {
            self.syntax = syntax
            self.summary = summary
        }
    }

    public var overview: String
    public var commands: [Command]

    public init(overview: String = "", commands: [Command] = []) {
        self.overview = overview
        self.commands = commands
    }

    /// No help (the default for plugins that don't provide any).
    public static let none = NativePluginHelp()
}

/// A registered native plugin's display info + live enabled state — what the
/// Plugins window needs to list and describe it.
public struct NativePluginInfo: Sendable, Equatable {
    public let metadata: NativePluginMetadata
    public let help: NativePluginHelp
    public let enabled: Bool
}

/// Cross-plugin facts the registry pre-answers once per GMCP dispatch and
/// hands to every plugin (#55). Native plugins are value types folded in
/// registration order — one plugin can't query another mid-fold — so facts
/// that *would* be a `CallPlugin` in MUSHclient (the reference soundpack asks
/// the chat plugin `checkIfMuted(player)` before playing a channel cue) are
/// answered up front by the registry via the same ``NativePlugin/call(_:_:)``
/// surface and passed in here.
public struct GMCPDispatchContext: Sendable, Equatable {
    /// `comm.channel` only: Chat Echo has the sending player muted, so
    /// sound/speech consumers should suppress their cues exactly like the
    /// echo itself is suppressed. Always false for other packages.
    public var speakerMuted: Bool

    public init(speakerMuted: Bool = false) {
        self.speakerMuted = speakerMuted
    }
}

/// A self-contained, *native* (Swift) Proteles plugin: a value-type reducer
/// that participates in the same effect pipeline as Lua plugins (ARCHITECTURE.md
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

    /// Overview + command list shown in the Plugins window. Default: empty.
    var help: NativePluginHelp { get }

    /// One-time setup (≈ MUSHclient `OnPluginInstall`), run when the plugin
    /// is registered or re-enabled. Default: no effects.
    mutating func install() -> [ScriptEffect]

    /// Run when the session connects (≈ `OnPluginConnect`). Fires on TCP
    /// connect — *before* auto-login — so use it only for out-of-band setup
    /// (telnet sub-negotiations, GMCP). Do NOT emit `.send`/`.execute` here:
    /// a game command sent pre-login is consumed as the name/password and
    /// breaks login. Defer game commands to a post-login signal (e.g. the
    /// first `room.info`). Default: none.
    mutating func connect() -> [ScriptEffect]

    /// Handle a typed command. Return `nil` to leave the input unhandled
    /// (it is sent to the MUD as usual); return an effect list — possibly
    /// empty — to *consume* the input (it is NOT sent) and apply those
    /// effects. Default: unhandled.
    mutating func handleCommand(_ input: String) -> [ScriptEffect]?

    /// React to an incoming styled line: a gag decision, effects, and/or a
    /// rewritten replacement line (text substitution). The plugin reads
    /// `line.text`/`line.runs` and may return `replacement` preserving the
    /// line's id/timestamp. Default: pass through (no gag, no effects).
    mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition

    /// React to a GMCP package update (`package` is the lowercased name,
    /// `json` its decoded payload). Default: no effects.
    mutating func onGMCP(package: String, json: String) -> [ScriptEffect]

    /// Context-aware variant of ``onGMCP(package:json:)``: `context` carries
    /// the registry's pre-answered cross-plugin facts (e.g. "this channel
    /// line's speaker is muted"). Default: delegates to the plain variant, so
    /// plugins that don't care implement only that one.
    mutating func onGMCP(
        package: String, json: String, context: GMCPDispatchContext
    ) -> [ScriptEffect]

    /// Synchronous callable entry points for `CallPlugin(id, fn, …)` from
    /// other plugins (the "usable by other plugins" surface). Default: none.
    func call(_ function: String, _ arguments: [LuaValue]) -> [LuaValue]

    /// The plugin's serialized state to persist per world (e.g. a user's
    /// substitution rules). `nil` means nothing to persist. Default: nil.
    var persistentState: Data? { get }

    /// Restore state previously produced by ``persistentState`` (called when
    /// a world loads). Default: no-op.
    mutating func restore(from data: Data)
}

public extension NativePlugin {
    var help: NativePluginHelp {
        .none
    }

    mutating func install() -> [ScriptEffect] {
        []
    }

    mutating func connect() -> [ScriptEffect] {
        []
    }

    mutating func handleCommand(_: String) -> [ScriptEffect]? {
        nil
    }

    mutating func onLine(_: Line) -> ScriptEngine.LineDisposition {
        .init()
    }

    mutating func onGMCP(package _: String, json _: String) -> [ScriptEffect] {
        []
    }

    mutating func onGMCP(
        package: String, json: String, context _: GMCPDispatchContext
    ) -> [ScriptEffect] {
        onGMCP(package: package, json: json)
    }

    func call(_: String, _: [LuaValue]) -> [LuaValue] {
        []
    }

    var persistentState: Data? {
        nil
    }

    mutating func restore(from _: Data) {}
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

    /// The registered plugins' info + current enabled state, in registration
    /// order (drives the Plugins window listing).
    public var listing: [NativePluginInfo] {
        entries.map {
            NativePluginInfo(metadata: $0.plugin.metadata, help: $0.plugin.help, enabled: $0.enabled)
        }
    }

    /// Fire `connect()` on every enabled plugin, concatenating effects.
    public mutating func connect() -> [ScriptEffect] {
        var effects: [ScriptEffect] = []
        for index in entries.indices where entries[index].enabled {
            effects.append(contentsOf: entries[index].plugin.connect())
        }
        return effects
    }

    /// Offer a typed command to each enabled plugin in order; the first to
    /// claim it wins. `nil` means no plugin handled it (send verbatim).
    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        for index in entries.indices where entries[index].enabled {
            if let effects = entries[index].plugin.handleCommand(input) { return effects }
        }
        return nil
    }

    /// Fold an incoming line through every enabled plugin in registration
    /// order: gags OR together, effects concatenate, and a plugin's
    /// rewritten line is fed to the next (a substitution pipeline).
    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        var disposition = ScriptEngine.LineDisposition()
        var current = line
        for index in entries.indices where entries[index].enabled {
            let result = entries[index].plugin.onLine(current)
            if result.gag { disposition.gag = true }
            disposition.effects.append(contentsOf: result.effects)
            if let replacement = result.replacement { current = replacement }
        }
        if current != line { disposition.replacement = current }
        return disposition
    }

    /// Fan a GMCP update to every enabled plugin, concatenating effects. The
    /// dispatch context is pre-answered once (cross-plugin facts — see
    /// ``GMCPDispatchContext``) and handed to every plugin.
    public mutating func onGMCP(package: String, json: String) -> [ScriptEffect] {
        let context = dispatchContext(package: package, json: json)
        var effects: [ScriptEffect] = []
        for index in entries.indices where entries[index].enabled {
            effects.append(
                contentsOf: entries[index].plugin
                    .onGMCP(package: package, json: json, context: context)
            )
        }
        return effects
    }

    /// Pre-answer the cross-plugin facts for one GMCP dispatch: for a
    /// `comm.channel` line, ask Chat Echo whether the speaker is muted (the
    /// reference soundpack's `CallPlugin(chat, "checkIfMuted", player)`,
    /// answered through the same ``NativePlugin/call(_:_:)`` surface). A
    /// disabled/absent Chat Echo answers nothing → not muted, exactly like
    /// the reference's non-zero `CallPlugin` rc.
    private func dispatchContext(package: String, json: String) -> GMCPDispatchContext {
        guard package.lowercased() == "comm.channel",
              let comm = try? JSONDecoder().decode(CommChannel.self, from: Data(json.utf8)),
              !comm.player.isEmpty
        else { return GMCPDispatchContext() }
        let verdict = call(
            id: ChatEcho.pluginID, function: "checkIfMuted", arguments: [.string(comm.player)]
        )
        return GMCPDispatchContext(speakerMuted: verdict.first == .boolean(true))
    }

    /// Route a `CallPlugin`-style call to an enabled plugin by id. Returns
    /// an empty result for an unknown/disabled id or unknown function.
    public func call(id: String, function: String, arguments: [LuaValue]) -> [LuaValue] {
        guard let entry = entries.first(where: { $0.plugin.metadata.id == id && $0.enabled }) else {
            return []
        }
        return entry.plugin.call(function, arguments)
    }

    // MARK: - Persistence

    /// A plugin's serialized state by id (`nil` if unknown or no state).
    public func persistentState(id: String) -> Data? {
        entries.first { $0.plugin.metadata.id == id }?.plugin.persistentState
    }

    /// Restore saved state into the matching registered plugins (by id).
    public mutating func restore(states: [String: Data]) {
        for index in entries.indices {
            if let data = states[entries[index].plugin.metadata.id] {
                entries[index].plugin.restore(from: data)
            }
        }
    }

    /// Apply persisted enabled/disabled flags (ids absent from the map keep
    /// their registration-time default).
    public mutating func applyEnabled(_ enabledByID: [String: Bool]) {
        for index in entries.indices {
            if let enabled = enabledByID[entries[index].plugin.metadata.id] {
                entries[index].enabled = enabled
            }
        }
    }
}
