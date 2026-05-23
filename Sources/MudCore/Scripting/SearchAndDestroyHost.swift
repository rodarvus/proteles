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

    public init() throws {
        runtime = try LuaRuntime()
    }

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

        // Curated host API (globals S&D calls), then the script itself.
        do {
            _ = try await runtime.run(Self.bindings)
            _ = try await runtime.run(core)
        } catch {
            throw HostError.loadFailed(String(describing: error))
        }
    }

    /// Whether a global Lua function of `name` is defined (for tests / sanity).
    public func functionExists(_ name: String) async -> Bool {
        await (try? runtime.string("type(\(name))")) == "function"
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

    -- Timers / automations (the real ones are registered natively) -----------
    function EnableTimer(name, flag) return 0 end
    function EnableTrigger(name, flag) return 0 end
    function EnableGroup(name, flag) return 0 end
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
