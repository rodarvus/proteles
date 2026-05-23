import Foundation

/// Runs the vendored Search-and-Destroy *logic* on a dedicated, sandboxed
/// ``LuaRuntime`` with a **curated** host binding — exactly the MUSHclient
/// functions S&D needs, backed by our `proteles.*` primitives (not the
/// generic `mush.lua` shim). The MUSHclient miniwindow (`Window*`/`Hyperlink`/
/// `movewindow`) is stubbed here and replaced by a native SwiftUI panel in
/// later stages; the search/campaign/gquest/DB logic is reused unchanged.
///
/// S1.2 scope: stand up the runtime, register S&D's modules, install the
/// bindings, and load `core.lua` (its functions become callable). Wiring the
/// triggers/aliases/timers + the data bridge + UI come in S1.3+.
public actor SearchAndDestroyHost {
    public enum HostError: Error, Equatable {
        case assetsMissing
        case loadFailed(String)
    }

    private let runtime: LuaRuntime
    /// The latest JSON model S&D published (via the `xg_draw_window` bridge).
    public private(set) var model: String?

    /// S&D's triggers/aliases/timers, parsed from the vendored plugin XML.
    /// These drive the host's own matching (S&D runs on its dedicated runtime,
    /// not the shared `ScriptEngine`), populated by ``load()``.
    public private(set) var automations: MUSHclientPlugin?

    // S&D's own automation engines (pure value types). S&D runs on a dedicated
    // runtime with curated bindings, so it can't share `ScriptEngine`'s engines
    // — the host drives matching itself and runs fired scripts on `runtime`.
    private var triggers = TriggerEngine()
    private var aliases = AliasEngine()
    private var timers = TimerEngine()
    /// Name → engine id, so S&D's `EnableTrigger`/`EnableTimer` (by name) can
    /// toggle the right rule.
    private var triggerIDsByName: [String: UUID] = [:]
    private var timerIDsByName: [String: UUID] = [:]

    public init() throws {
        runtime = try LuaRuntime()
    }

    /// Point S&D at its data directory — `GetInfo(66)` (where it finds the
    /// mapper DB as `<WorldName>.db` and keeps its own `SnDdb.db`) and the
    /// lsqlite3 sandbox root. Call before ``load()`` (S&D captures the DB
    /// paths from `GetInfo(66)` at load time).
    public func configure(directory: String) async {
        let suffixed = directory.hasSuffix("/") ? directory : directory + "/"
        var context = PluginContext.default
        context.pluginID = Self.pluginID
        context.pluginName = "Search_and_Destroy"
        context.appDirectory = suffixed // GetInfo(66)
        context.worldDirectory = suffixed
        context.pluginDirectory = suffixed // GetInfo(60)
        await runtime.setPluginContext(context)
        await runtime.setSQLiteDirectory(directory)
    }

    /// S&D's well-known MUSHclient plugin id.
    public static let pluginID = "30000000537461726C696E67"

    /// Register S&D's modules + curated bindings and load its `core.lua`.
    /// Throws if the vendored script is missing or fails to compile/run.
    public func load() async throws {
        guard let core = SearchAndDestroyAssets.core else { throw HostError.assetsMissing }

        // S&D's `require`/`dofile` targets resolve from these bundled modules
        // (the loader falls back to a bundled module by basename for dofile).
        await runtime.registerModules(SearchAndDestroyAssets.helperModules) // wait, constants, area data
        await runtime.registerModules(LuaRuntime.standardHelpers.filter {
            ["serialize", "tprint", "json", "aardwolf_colors"].contains($0.key)
        })
        await runtime.registerModule("movewindow", source: Self.movewindowStub)

        // Curated host API (globals S&D calls), then the script itself. S&D's
        // `xg_draw_window` carries a small [Proteles bridge] block that
        // publishes its model (it must live in core.lua's scope to read the
        // display locals); we just capture the published JSON in `run`.
        do {
            _ = try await runtime.run(Self.bindings)
            _ = try await runtime.run(core)
        } catch {
            throw HostError.loadFailed(String(describing: error))
        }

        try loadAutomations()
    }

    /// Parse S&D's triggers/aliases/timers from the vendored plugin XML into
    /// ``automations``. The XML carries PCRE regexes with `(?<name>…)` groups
    /// that aren't valid XML attribute content, so it's normalised first
    /// (``SearchAndDestroyXML``) before the shared ``MUSHclientPluginLoader``
    /// reads it. Idempotent; also runs as part of ``load()``.
    public func loadAutomations() throws {
        guard let xml = SearchAndDestroyAssets.pluginXML else { throw HostError.assetsMissing }
        let plugin: MUSHclientPlugin
        do {
            plugin = try MUSHclientPluginLoader.parse(xml: SearchAndDestroyXML.normalise(xml))
        } catch {
            throw HostError.loadFailed(String(describing: error))
        }
        automations = plugin
        seedEngines(from: plugin)
    }

    /// Load S&D's automations into the host's engines. Patterns that don't
    /// compile (a PCRE construct ICU rejects) are skipped, best-effort, so one
    /// odd trigger can't disable the whole plugin.
    private func seedEngines(from plugin: MUSHclientPlugin) {
        triggers = TriggerEngine()
        aliases = AliasEngine()
        timers = TimerEngine()
        triggerIDsByName.removeAll()
        timerIDsByName.removeAll()

        for trigger in plugin.triggers {
            guard (try? triggers.add(trigger)) != nil else { continue }
            if let name = trigger.name { triggerIDsByName[name] = trigger.id }
        }
        for alias in plugin.aliases {
            try? aliases.add(alias)
        }
        for timer in plugin.timers {
            guard let id = try? timers.add(timer) else { continue }
            if let name = timer.label { timerIDsByName[name] = id }
        }
    }

    // MARK: - Dispatch (the session drives these)

    /// Run an incoming MUD line through S&D's triggers, returning the outward
    /// effects (sends/echoes/published model). Enable/disable effects S&D's
    /// Lua emitted are applied to the host's own engines, not returned.
    public func process(_ line: String) async -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        for firing in triggers.process(line) {
            out += await applyFiring(send: firing.send, script: firing.script, match: firing.match)
        }
        return out
    }

    /// Offer a typed command to S&D's aliases. Returns the resulting effects,
    /// or `nil` if no S&D alias matched (so the caller sends it normally).
    public func expandCommand(_ input: String) async -> [ScriptEffect]? {
        let firings = aliases.match(input)
        guard !firings.isEmpty else { return nil }
        var out: [ScriptEffect] = []
        for firing in firings {
            guard let send = firing.send else { continue }
            switch firing.target {
            case .script:
                await out += consume(runScript(send, match: firing.match))
            case .world: out.append(.send(send))
            case .execute: out.append(.execute(send))
            case .output: out.append(.echo(send))
            }
        }
        return out
    }

    /// The next instant any enabled S&D timer is due, or nil if none — so the
    /// session's timer loop can include S&D's deadlines.
    public func nextTimerDeadline() -> Date? {
        timers.nextDeadline()
    }

    /// Fire any of S&D's timers that are due at `now` (e.g. the one-shot
    /// `tim_init_plugin` bootstrap and the navigation tick timers).
    public func fireTimers(at now: Date = Date()) async -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        for firing in timers.due(at: now) {
            out += await applyFiring(send: firing.send, script: firing.script, match: nil)
        }
        return out
    }

    private func applyFiring(send: String?, script: String?, match: TriggerMatch?) async -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        if let send, !send.isEmpty { out.append(.send(send)) }
        if let script, !script.isEmpty {
            await out += consume(runScript(script, match: match))
        }
        return out
    }

    private func runScript(_ script: String, match: TriggerMatch?) async -> [ScriptEffect] {
        do {
            return try await runtime.runScript(
                script,
                matches: match?.captures ?? [],
                named: match?.named ?? [:]
            )
        } catch {
            return []
        }
    }

    /// Apply S&D's host-internal enable/disable effects to the host's engines
    /// and capture the latest published model; return the remaining outward
    /// effects (sends/echoes/publishModel) for the session to apply.
    private func consume(_ effects: [ScriptEffect]) -> [ScriptEffect] {
        var out: [ScriptEffect] = []
        for effect in effects {
            switch effect {
            case .enableTrigger(let name, let on):
                if let id = triggerIDsByName[name] { triggers.setEnabled(on, id: id) }
            case .enableTimer(let name, let on):
                if let id = timerIDsByName[name] { timers.setEnabled(on, id: id) }
            case .enableGroup(let name, let on):
                triggers.setGroupEnabled(on, group: name)
                timers.setGroupEnabled(on, group: name)
            case .publishModel(let json):
                model = json
                out.append(effect)
            default:
                out.append(effect)
            }
        }
        return out
    }

    /// Whether a global Lua function of `name` is defined (for tests / sanity).
    public func functionExists(_ name: String) async -> Bool {
        await (try? runtime.string("type(\(name))")) == "function"
    }

    /// Run a Lua chunk in S&D's runtime, returning the effects its output
    /// calls produced (Note/ColourNote/Hyperlink/Send/…). Also captures the
    /// latest published model snapshot into ``model``.
    @discardableResult
    public func run(_ script: String) async throws -> [ScriptEffect] {
        let effects = try await runtime.run(script)
        for effect in effects {
            if case .publishModel(let json) = effect { model = json }
        }
        return effects
    }

    /// Evaluate a Lua expression to a string (`tostring`), or nil on error.
    public func evaluate(_ expression: String) async -> String? {
        try? await runtime.string(expression)
    }

    // MARK: - Curated bindings

    /// The MUSHclient API S&D uses, defined as globals over `proteles.*`.
    /// Output/comms/vars/timers map to real primitives; the miniwindow + a few
    /// options are stubs (replaced by native UI / wired in later stages).
    private static let bindings = """
    -- Lua 5.1 module system (the sandbox removes it; some vendored helper libs
    -- like `wait`/`check` declare themselves with `module(..., package.seeall)`).
    package = package or { loaded = {}, path = "", cpath = "" }
    package.seeall = function(m) setmetatable(m, { __index = _G }) end
    function module(name, ...)
      local m = package.loaded[name]
      if m == nil then m = {}; package.loaded[name] = m end
      m._NAME = name; m._M = m
      if name and not name:find("%.") then _G[name] = m end
      for _, modifier in ipairs({...}) do modifier(m) end
      setfenv(2, m)  -- the calling chunk's environment becomes the module
    end

    -- Output + comms ---------------------------------------------------------
    function Send(s) proteles.send(s); return 0 end
    function SendNoEcho(s) proteles.sendNoEcho(s); return 0 end
    function Execute(s) proteles.execute(s); return 0 end
    function Note(...) proteles.echo(table.concat({...}, "\\t")) end
    function ColourNote(...) proteles.colourNote(...) end
    function ColourTell(...) proteles.colourNote(...) end
    function AnsiNote(s) proteles.echoAnsi(s) end
    function Tell(s) proteles.echo(tostring(s)) end
    function Hyperlink(action, text) proteles.echo(tostring(text)) end  -- native links: later

    -- Variables / identity ---------------------------------------------------
    function GetVariable(name) return proteles.getVar(name) end
    function SetVariable(name, value) proteles.setVar(name, tostring(value)); return 0 end
    function DeleteVariable(name) proteles.deleteVar(name); return 0 end
    function GetPluginID() return proteles.pluginID() end
    function GetInfo(n) return proteles.info(n) end
    function WorldName() return proteles.info(2) or "Aardwolf" end
    function GetPluginInfo(id, n)
      if n == 1 then return "Search_and_Destroy"
      elseif n == 19 then return "5.99"
      elseif n == 20 then return proteles.info(60)
      else return nil end
    end

    -- Inter-plugin ------------------------------------------------------------
    function CallPlugin(id, fn, ...)
      if id == "b6eae87ccedd84f510b74714" then proteles.mapperCall(fn, ...); return 0 end
      return 0, proteles.call(fn, ...)
    end
    function BroadcastPlugin(msg, text) proteles.broadcast(msg, text); return 0 end

    -- Timers / automations: S&D gates its CP/GQ flow by toggling trigger
    -- groups, so these drive the host's own engines (booleanised first).
    function EnableTimer(name, flag) proteles.enableTimer(name, flag and true or false); return 0 end
    function EnableTrigger(name, flag) proteles.enableTrigger(name, flag and true or false); return 0 end
    function EnableGroup(name, flag) proteles.enableGroup(name, flag and true or false); return 0 end
    function AddTimer(...) return 0 end
    function DeleteTimer(...) return 0 end
    function DoAfterSpecial(...) return 0 end
    function DoAfter(...) return 0 end
    function SetStatus(...) end
    function GetOption(...) return 0 end
    function GetAlphaOption(...) return "" end
    function SetOption(...) return 0 end

    -- Plugin discovery / misc (stubs — single-plugin curated runtime) --------
    function IsPluginInstalled(id) return false end
    function PluginSupports(id, fn) return false end
    function GetPluginList() return {} end
    function EnablePlugin(id, flag) return 0 end
    function Replace(...) return 0 end
    function Repaint() end
    function Redraw() end
    function SetCursor(...) return 0 end
    function Sound(...) return 0 end
    function PlaySound(...) return 0 end
    function Hash(s) return tostring(s) end
    function FixupHTML(s) return tostring(s) end
    function GetUniqueNumber() return 0 end
    function version_check(...) return true end

    -- String helper -----------------------------------------------------------
    function Trim(s) if s == nil then return "" end return (tostring(s):gsub("^%s*(.-)%s*$", "%1")) end

    -- Bit ops (MUSHclient exposes `bit`; used by hotspot flag tests) ----------
    if bit == nil then
      bit = { band = function(a, b) return 0 end, bor = function(a, b) return 0 end }
    end

    -- Miniwindow: stubbed (replaced by the native SwiftUI panel). Drawing is a
    -- no-op; geometry queries return 0; `WindowInfo`-style reads return 0.
    local function noop() return 0 end
    for _, name in ipairs({
      "WindowCreate","WindowShow","WindowDelete","WindowResize","WindowPosition",
      "WindowRectOp","WindowCircleOp","WindowLine","WindowText","WindowFont",
      "WindowAddHotspot","WindowDeleteHotspot","WindowMoveHotspot","WindowDragHandler",
      "WindowScrollwheelHandler","WindowMenu","WindowSetPixel","WindowImage",
      "WindowLoadImageMemory","WindowDrawImageAlpha","WindowDeleteAllHotspots",
      "WindowTextWidth","WindowFontInfo","WindowInfo","WindowHotspotInfo",
      "WindowFontList","WindowImageInfo","WindowGetImageAlpha","WindowBlendImage",
      "WindowMergeImageAlpha","WindowFilter","WindowGradient","WindowPolygon",
      "WindowArc","WindowBezier","WindowRectangle","WindowCircle","WindowEllipse",
      "BroadcastPlugin"
    }) do
      if _G[name] == nil then _G[name] = noop end
    end
    function WindowInfo(win, n) return 0 end
    function WindowTextWidth(win, font, text) return 0 end
    function WindowFontInfo(win, font, n) return 0 end
    """

    /// A no-op `movewindow` (the dragging helper) — the native panel handles
    /// placement, so plugins that `require "movewindow"` get a quiet stub.
    private static let movewindowStub = """
    local M = {}
    function M.install(win, ...) return { window_left = 0, window_top = 0, width = 0, height = 0 } end
    function M.save_state(...) end
    function M.add_drag_handler(...) end
    function M.add_to_menu(...) end
    return M
    """
}
