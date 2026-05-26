import Foundation

/// Accessors for the vendored **dinv** inventory-manager plugin (bundled with
/// MudCore; see `Resources/dinv/PROVENANCE.md`). dinv runs verbatim through the
/// MUSHclient compatibility shim: its `dinv.xml` bootstrap `dofile`s
/// `dinv_init.lua`, which in turn `dofile`s 20 modules and `require`s the
/// standard helpers (all provided by the shim, including an inert `async`).
///
/// We register dinv's modules with the runtime's module loader keyed by
/// **basename** (no `.lua`), so the plugin's `dofile(dir .. "dinv_X.lua")`
/// resolves from the bundle (the loader falls back to a bundled module matching
/// the file's basename) — no on-disk copy needed.
public enum DinvAssets {
    private static let subdirectory = "dinv"

    /// The plugin's well-known MUSHclient id (matches `dinv.xml`).
    public static let pluginID = "731f94b0f2b54345f836bbaf"

    /// The bootstrap module names dinv `dofile`s (basename keys, no extension).
    /// `dinv_init` is the entry point (loaded by `dinv.xml`'s `<script>`); it
    /// loads the rest. Order is irrelevant for registration — the loader
    /// resolves each on demand.
    public static let moduleNames = [
        "dinv_init", "dinv_db", "dinv_cli", "dinv_items", "dinv_report",
        "dinv_data", "dinv_cache", "dinv_priority", "dinv_score", "dinv_set",
        "dinv_equipment", "dinv_statbonus", "dinv_analyze", "dinv_usage",
        "dinv_unused", "dinv_tags", "dinv_consume", "dinv_portal", "dinv_regen",
        "dinv_migrate", "dinv_dbot"
    ]

    /// A vendored Lua module's source by basename, or `nil` if missing.
    public static func lua(_ name: String) -> String? {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "lua", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// All dinv modules keyed by basename, ready for the runtime's module
    /// loader (`registerModules`). Missing files are skipped.
    public static var modules: [String: String] {
        moduleNames.reduce(into: [:]) { result, name in result[name] = lua(name) }
    }

    /// The plugin XML (the `<plugin>` definition + aliases + the `<script>`
    /// bootstrap), parsed by ``MUSHclientPluginLoader``.
    public static var pluginXML: String? {
        guard let url = Bundle.module.url(
            forResource: "dinv", withExtension: "xml", subdirectory: subdirectory
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// A Lua chunk that instruments dinv's init chain + execute-queue for
    /// debugging. **Debug/test aid only** — no longer installed in live
    /// sessions (it's invoked by the offline `DinvBuildHarnessTests` to make the
    /// harness trace as rich as a session `.log`). Kept because it's the lens
    /// that pinned the build deadlock and is the natural tool for the next
    /// dinv issue (e.g. the container-identify phase).
    /// Run *in dinv's environment* after load and before the `char.base`
    /// broadcast that kicks off init. Two layers:
    ///
    /// 1. Force dinv's own `DEBUG` notifications on and *lock* them, so the
    ///    notify module's `atActive` (which restores a stored level) can't turn
    ///    them back off — this surfaces dinv's rich native `dbot.debug` trace.
    /// 2. Entry/exit `[dinv-DBG]` markers around the init chain. Crucially the
    ///    wrappers call through **without `pcall`**: the chain runs inside a
    ///    `wait.make` coroutine that *yields* on MUD probes, and Lua 5.1 cannot
    ///    yield across a `pcall`/C boundary. A logged `->` with no matching `<-`
    ///    pinpoints exactly where the coroutine yields and never resumes.
    ///
    /// All markers reach the session transcript (every `Note` is teed there),
    /// so `dinv build` live then shows the precise failure point.
    public static let debugTraceSource = """
    dbot.notify.level[notifyLevelDebug].enabled = true
    local __origSetLevel = dbot.notify.setLevel
    function dbot.notify.setLevel(value, endTag, isVerbose)
      local r = __origSetLevel(value, endTag, isVerbose)
      dbot.notify.level[notifyLevelDebug].enabled = true
      return r
    end

    local function __wrap(tbl, key, label)
      if type(tbl) ~= "table" then Note("[dinv-DBG] " .. label .. ": no container"); return end
      local orig = tbl[key]
      if type(orig) ~= "function" then Note("[dinv-DBG] " .. label .. ": MISSING"); return end
      tbl[key] = function(...)
        Note("[dinv-DBG] -> " .. label)
        local r = orig(...)
        Note("[dinv-DBG] <- " .. label .. " = " .. tostring(r))
        return r
      end
    end

    local __origBroadcast = OnPluginBroadcast
    function OnPluginBroadcast(...)
      Note("[dinv-DBG] -> OnPluginBroadcast")
      if __origBroadcast then __origBroadcast(...) end
      Note("[dinv-DBG] <- OnPluginBroadcast")
    end

    __wrap(inv.init, "atActive", "inv.init.atActive")
    __wrap(inv.init, "atActiveCR", "inv.init.atActiveCR")
    __wrap(dbot.init, "atActive", "dbot.init.atActive")
    __wrap(dinv_db, "open", "dinv_db.open")
    __wrap(inv.items, "build", "inv.items.build")

    -- Execute-queue / fence / callback flow (the build deadlock lives here):
    -- entry/exit markers show how far dequeueCR gets and where it stalls.
    __wrap(dbot.execute.queue, "dequeueCR", "dequeueCR")
    __wrap(dbot.execute.queue, "fence", "fence")
    __wrap(dbot.callback, "wait", "callback.wait")
    __wrap(dbot.prompt, "disable", "prompt.disable")
    __wrap(dbot.prompt, "enable", "prompt.enable")
    local __origBypass = dbot.execute.queue.bypass
    if type(__origBypass) == "function" then
      dbot.execute.queue.bypass = function(command)
        Note("[dinv-DBG] bypass -> " .. tostring(command))
        return __origBypass(command)
      end
    end
    local __origPushFast = dbot.execute.queue.pushFast
    if type(__origPushFast) == "function" then
      dbot.execute.queue.pushFast = function(command)
        Note("[dinv-DBG] pushFast <- " .. tostring(command))
        return __origPushFast(command)
      end
    end
    """
}
