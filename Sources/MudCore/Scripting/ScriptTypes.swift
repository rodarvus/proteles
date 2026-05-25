import Foundation

/// A value crossing the Lua ↔ Swift boundary. The minimal set the host
/// API needs today (scalars); tables follow when the event bus / RPC land.
public enum LuaValue: Sendable, Equatable {
    case `nil`
    case boolean(Bool)
    case number(Double)
    case string(String)
    /// A reference to a Lua function held in the registry (`luaL_ref`), so
    /// Swift can store it (event handlers, exported callables) and invoke
    /// it later. Opaque handle — not meant to be inspected.
    case functionRef(Int32)

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var booleanValue: Bool? {
        if case .boolean(let value) = self { value } else { nil }
    }
}

/// A side effect a script asked the host to perform, recorded while a Lua
/// chunk runs and applied by the host (the session) after it returns.
///
/// Keeping these as inert values — rather than letting Lua call the
/// (async) network/scrollback APIs directly from inside `pcall` — keeps
/// the C↔Swift boundary synchronous and the script engine unit-testable
/// without a live session.
public enum ScriptEffect: Sendable, Equatable {
    /// Send a command to the MUD (raw, as `proteles.send`).
    case send(String)
    /// Send without local echo (passwords).
    case sendNoEcho(String)
    /// Run a command as if the user typed it (through aliases).
    case execute(String)
    /// Print plain text to the scrollback.
    case echo(String)
    /// Print coloured text to the scrollback. `foreground`/`background`
    /// are colour names (resolved by the host); `nil` uses defaults.
    case note(text: String, foreground: String?, background: String?)
    /// Print a multi-colour line built from `ColourNote`'s `(fore, back,
    /// text)` triples — one styled run per segment, so per-segment colours
    /// survive (backs the MUSHclient `ColourNote`/`ColourTell` shim and is
    /// reusable by native features that emit multi-colour lines).
    case colourNote([NoteSegment])
    /// Send a GMCP packet to the server (the payload is framed as
    /// `IAC SB 201 <payload> IAC SE`). Backs `Send_GMCP_Packet`.
    case sendGMCP(String)
    /// Print Aardwolf `@`-coded text to the scrollback, rendered as styled
    /// runs (`proteles.echoAard`).
    case echoAard(String)
    /// Print ANSI-SGR-coded text to the scrollback, rendered as styled runs
    /// (the shim's `AnsiNote`).
    case echoAnsi(String)
    /// Remove a runtime-registered trigger by name (MUSHclient `DeleteTrigger`).
    case removeTrigger(String)
    /// Re-inject text as if it had arrived from the MUD (MUSHclient's
    /// `Simulate`): the host feeds each line back through the inbound pipeline
    /// so triggers (user + S&D) see it and it displays. S&D uses this for its
    /// `xtest` harness and the `notes` header.
    case simulate(String)
    /// Suspend (or resume) the scripting engines: while suspended, typed
    /// input is sent verbatim (no alias/native-command expansion), incoming
    /// lines pass through untouched (no triggers/native reactions), and
    /// timers don't fire. Backs the native Note-mode plugin.
    case setAutomationsSuspended(Bool)
    /// Persist the named native plugin's current state to the per-world
    /// store (emitted by a plugin after a command mutates its state, e.g.
    /// adding a `#sub` rule).
    case persistPluginState(id: String)
    /// Toggle one of Aardwolf's telnet options (sub-negotiation 102), e.g.
    /// enabling the ASCII-map / room-desc tag streams. Framed as
    /// `IAC SB 102 <option> <1=on|2=off> IAC SE`.
    case aardwolfTelnet(option: Int, on: Bool)
    /// Publish a captured ASCII map block (its styled lines) to the Map
    /// panel; an empty array clears it.
    case updateMap([Line])
    /// A `CallPlugin(<mapper>, function, args…)` routed to the native mapper.
    /// The host runs it and delivers any resulting broadcasts (e.g. the
    /// 500/501 path results) back through `OnPluginBroadcast`.
    case mapperCall(function: String, args: [String])
    /// A plugin published a structured snapshot (JSON) of its model for a
    /// native panel to render — the inverse of GMCP-in (e.g. Search-and-
    /// Destroy's window state). The host decodes + forwards it to the UI.
    case publishModel(String)
    /// Enable/disable a named trigger (MUSHclient `EnableTrigger`). Consumed
    /// by a plugin host that owns its own automation engines (e.g. the
    /// Search-and-Destroy host, whose Lua gates its flow this way).
    case enableTrigger(name: String, on: Bool)
    /// Enable/disable a named timer (MUSHclient `EnableTimer`).
    case enableTimer(name: String, on: Bool)
    /// Enable/disable a named alias (MUSHclient `EnableAlias`).
    case enableAlias(name: String, on: Bool)
    /// Enable/disable every trigger and timer in a named group (MUSHclient
    /// `EnableGroup`).
    case enableGroup(name: String, on: Bool)
    /// Schedule a one-shot deferred action after `seconds` (MUSHclient
    /// `DoAfter`/`DoAfterSpecial`). `isScript` runs `body` as Lua in the
    /// owning plugin's runtime; otherwise `body` is sent to the MUD. Consumed
    /// by a plugin host that owns its own timer engine (e.g. Search-and-
    /// Destroy, which defers `do_cp_check`, area scans, etc. this way).
    case scheduleAfter(seconds: Double, isScript: Bool, body: String)
    /// Register a trigger at runtime (MUSHclient `AddTriggerEx`). `flags` is the
    /// MUSHclient bitfield (Enabled/OmitFromOutput/IgnoreCase/RegularExpression);
    /// `script` is the handler function name. Consumed by a plugin host that
    /// owns its own trigger engine (Search-and-Destroy's scan/consider).
    case addTrigger(name: String, pattern: String, flags: Int, script: String)
    /// Set a runtime trigger's group (MUSHclient `SetTriggerOption(.,"group",.)`),
    /// so `EnableTriggerGroup` can toggle it.
    case setTriggerGroup(name: String, group: String)
}

/// One coloured segment of a ``ScriptEffect/colourNote(_:)`` line. `text`
/// is rendered with `foreground`/`background`, each a colour *name*
/// (`"red"`, `"white"`, …) or a `#RRGGBB` hex string; `nil` means the
/// terminal default for that channel. Resolved to concrete styling by the
/// host.
public struct NoteSegment: Sendable, Equatable {
    public let text: String
    public let foreground: String?
    public let background: String?

    public init(text: String, foreground: String? = nil, background: String? = nil) {
        self.text = text
        self.foreground = foreground
        self.background = background
    }
}
