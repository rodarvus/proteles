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
/// One coloured segment of a matched line, supplied to a trigger's script as
/// MUSHclient's 4th `styles` argument (an array of `{text, textcolour,
/// backcolour, style, length}`). `textColour`/`backColour` are BGR-packed ints
/// (red in the low byte) — the form MUSHclient's `RGBColourToName` decodes — so
/// handlers like Search-and-Destroy's `scan_mob`/`consider_trigger` can
/// re-render the matched line in its original colours.
public struct ScriptStyleRun: Sendable, Equatable {
    public let text: String
    public let textColour: Int
    public let backColour: Int

    public init(text: String, textColour: Int, backColour: Int) {
        self.text = text
        self.textColour = textColour
        self.backColour = backColour
    }

    /// Build the MUSHclient `styles` array for a matched line: one entry per
    /// styled run (its `textcolour`/`backcolour` as ``MUSHColour`` ints), with
    /// default-colour entries filling any gaps, covering the whole line in
    /// order — so `styles[1]` is the first cell's colour, as plugins expect.
    public static func mushStyles(text: String, runs: [StyledRun]) -> [ScriptStyleRun] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }
        let defaultFg = MUSHColour.normal[7]
        var result: [ScriptStyleRun] = []
        var cursor = 0
        func emit(_ lower: Int, _ upper: Int, _ fg: Int, _ bg: Int) {
            guard lower < upper, lower >= 0, upper <= nsText.length else { return }
            result.append(ScriptStyleRun(
                text: nsText.substring(with: NSRange(location: lower, length: upper - lower)),
                textColour: fg,
                backColour: bg
            ))
        }
        for run in runs.sorted(by: { $0.utf16Range.lowerBound < $1.utf16Range.lowerBound }) {
            let lower = run.utf16Range.lowerBound
            let upper = run.utf16Range.upperBound
            guard lower >= cursor else { continue } // skip overlapping runs
            if lower > cursor { emit(cursor, lower, defaultFg, 0) } // default-colour gap
            let fg = run.style.foreground.map(MUSHColour.int(for:)) ?? defaultFg
            let bg = run.style.background.map(MUSHColour.int(for:)) ?? 0
            emit(lower, upper, fg, bg)
            cursor = upper
        }
        if cursor < nsText.length { emit(cursor, nsText.length, defaultFg, 0) }
        return result
    }
}

public enum ScriptEffect: Sendable, Equatable {
    /// Send a command to the MUD (raw, as `proteles.send`).
    case send(String)
    /// Send without local echo (passwords).
    case sendNoEcho(String)
    /// Run a command as if the user typed it (through aliases).
    case execute(String)
    /// Print plain text to the scrollback.
    case echo(String)
    /// Raise a native user notification from a script/plugin (`Notify` /
    /// `proteles.notify`). Surfaced via the macOS notification layer, gated by
    /// the user's master notifications enable. The phase-2 extensibility hook.
    case notify(title: String, body: String)
    /// A script/plugin change to the command-button bar (`Button.*` / #15). The
    /// session forwards it to the app, which applies it to the live bar.
    case button(ButtonCommand)
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
    /// Inject a *synthesized* GMCP message into the **inbound** path as if it
    /// had arrived from the server — the host routes it through the same
    /// dispatch as a real packet (state, chat, mapper, plugin broadcasts). The
    /// inverse of ``sendGMCP``. Backs the native GMCP handler's config-state
    /// synthesis: Aardwolf emits no `config` GMCP when prompt/compact are
    /// toggled via commands, so we synthesize one from the text feedback (this
    /// mirrors aard_GMCP_handler's `OnPluginTelnetSubnegotiation(201, …)`).
    case injectGMCP(package: String, json: String)
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
    /// Tear down and re-instantiate a plugin by id (MUSHclient `ReloadPlugin`).
    /// The host routes by kind: native plugins disable→enable (re-running
    /// `install()`); the bundled dinv and on-disk MUSHclient plugins are
    /// unloaded (their env + owned triggers/aliases/timers cleared) and loaded
    /// fresh. Backs `dinv reload` (and any plugin's self-reload).
    case reloadPlugin(id: String)
    /// Toggle one of Aardwolf's telnet options (sub-negotiation 102), e.g.
    /// enabling the ASCII-map / room-desc tag streams. Framed as
    /// `IAC SB 102 <option> <1=on|2=off> IAC SE`.
    case aardwolfTelnet(option: Int, on: Bool)
    /// Publish a captured ASCII map block (its styled lines) to the Map
    /// panel; an empty array clears it.
    case updateMap([Line])
    /// Set the witnessed-tick anchor for the status-bar countdown (a `Date`,
    /// or `nil` to clear). Emitted by the native `TickTimer` plugin on each
    /// `comm.tick`; routing it through an effect (rather than decoding in the
    /// GMCP store) lets the plugin's enabled flag gate it — disable the plugin
    /// and the ticks stop, so the readout self-hides.
    case updateTick(Date?)
    /// A `CallPlugin(<mapper>, function, args…)` routed to the native mapper.
    /// The host runs it and delivers any resulting broadcasts (e.g. the
    /// 500/501 path results) back through `OnPluginBroadcast`.
    case mapperCall(function: String, args: [String])
    /// `CallPlugin(<S&D id>, fn, …)` from a shim plugin, bridged to the native
    /// S&D host (the user plugin's campaign mode drives `do_cp_check` etc.).
    case callSearchAndDestroy(function: String, args: [String])
    /// A plugin asked the native Chat Capture plugin to store a line from
    /// outside (`CallPlugin(<chat-capture id>, "storeFromOutside", text, tab)`)
    /// — the bridge to native chat for rsocial/hadar_spellup etc. The host
    /// appends it to the ``ChatStore`` under `channel` (falling back to a
    /// generic capture channel). `text` may carry Aardwolf `@`-codes.
    case chatCapture(text: String, channel: String)
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
    /// `script` is the handler function name. `sequence` is the MUSHclient
    /// evaluation order (default 100; lower fires first) — honouring it is
    /// essential: dinv registers its wish-capture trigger at sequence 0 so it
    /// fires *before* any co-loaded plugin's stop-on-match (`keep_evaluating="n"`)
    /// trigger that would otherwise pre-empt it on the owned wish lines. Consumed
    /// by a plugin host that owns its own trigger engine (Search-and-Destroy's
    /// scan/consider).
    case addTrigger(name: String, pattern: String, flags: Int, script: String, sequence: Int)
    /// Register a runtime alias (MUSHclient `AddAlias`). `flags` is the
    /// `alias_flag` bitfield (Enabled/RegularExpression); `script` is the
    /// handler function name. Consumed by the plugin host into its alias engine
    /// (e.g. dinv's regen `sleep` alias).
    case addAlias(name: String, pattern: String, flags: Int, script: String)
    /// Set a runtime trigger's group (MUSHclient `SetTriggerOption(.,"group",.)`),
    /// so `EnableTriggerGroup` can toggle it.
    case setTriggerGroup(name: String, group: String)
    /// Set another `SetTriggerOption` option on a named trigger by mutating it on
    /// the engine — so it works for XML-plugin-defined triggers too, not just
    /// shim-registered ones. `value` is the raw MUSHclient option string (booleans
    /// as y/n/0/1, sequence as a number, match as the pattern). Recognised options:
    /// omit_from_output, keep_evaluating, ignore_case, sequence, match.
    case setTriggerOption(name: String, option: String, value: String)
    /// Perform an outbound HTTP(S) request for a plugin's `async` helper. The
    /// host runs it off-actor (URLSession), then re-enters the script engine
    /// with the response to fire the plugin's stored Lua callback (kept in the
    /// runtime keyed by `request.id`). Allowed freely (MUSHclient parity).
    case httpRequest(HTTPRequest)
}

/// An outbound HTTP request a plugin's `async` helper asked for (the network
/// half of `doAsyncRemoteRequest`/`HEAD`/`GETFILE`). `id` keys the stored Lua
/// callback in the ``LuaRuntime``; the host performs the request and re-enters
/// the engine with the response.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case get = "GET", post = "POST", head = "HEAD"
    }

    public let id: Int
    public let url: String
    public let method: Method
    /// POST body, or nil for GET/HEAD.
    public let body: String?
    /// A GETFILE target path (the response body is written there, inside the
    /// plugin sandbox), or nil for a normal request.
    public let savePath: String?
    public let timeout: Double

    public init(
        id: Int,
        url: String,
        method: Method,
        body: String? = nil,
        savePath: String? = nil,
        timeout: Double
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.body = body
        self.savePath = savePath
        self.timeout = timeout
    }
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
    /// Makes the segment a clickable hyperlink (native `proteles.hyperlink`
    /// and the MUSHclient `Hyperlink` shim build linked segments).
    public let link: LineLink?

    public init(
        text: String,
        foreground: String? = nil,
        background: String? = nil,
        link: LineLink? = nil
    ) {
        self.text = text
        self.foreground = foreground
        self.background = background
        self.link = link
    }
}
