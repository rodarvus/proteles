import CLua
import Foundation

/// The MUSHclient world-API compatibility shim (Phase 6, PLAN.md §7.3).
///
/// `loadCompatShim()` installs a set of global Lua functions
/// (`Send`, `Note`, `ColourNote`, `GetVariable`, `GetInfo`, …) that the
/// Aardwolf plugin corpus calls, implemented on top of the native
/// `proteles.*` API. This is the Tier-1 surface — the ~15 methods that
/// dominate the corpus (≈ColourNote 276, Note 230, Set/GetVariable 390,
/// GetInfo 165, CallPlugin 139, GetPluginID 80, EnableTrigger 74, …).
///
/// The XML plugin loader (next increment) installs this into each plugin's
/// environment and bundles the helper libraries (`json`, `serialize`,
/// `gmcphelper`, …) via a controlled module loader. Name-based
/// `EnableTrigger`/`Timer`/`Group` are stubs here — they become real once
/// the loader registers named triggers.
public extension LuaRuntime {
    /// Install the compatibility globals into the Lua state. Idempotent.
    func loadCompatShim() throws {
        _ = try run(Self.compatShimSource)
    }

    /// Call a global Lua function by name (e.g. a plugin lifecycle callback
    /// like `OnPluginInstall`), returning the effects it recorded. A no-op
    /// when the global isn't a function. Errors surface as a red note rather
    /// than throwing, so a broken callback can't abort the host.
    @discardableResult
    func callGlobal(_ name: String, _ arguments: [LuaValue] = []) -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        defer { releaseTransientRefs() }
        clua_getglobal(state, name)
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            clua_pop(state, 1)
            return effects
        }
        for argument in arguments {
            luaPushValue(state, argument)
        }
        if lua_pcall(state, Int32(arguments.count), 0, 0) != 0 {
            effects.append(.note(
                text: "Lua callback error in \(name): \(Self.popMessage(state))",
                foreground: "red",
                background: nil
            ))
        }
        return effects
    }

    /// The shim source, applied on top of an existing `proteles` table.
    internal nonisolated static let compatShimSource = """
    -- MUSHclient world-API compatibility shim, mapped onto proteles.*.
    local proteles = proteles

    error_code = {
      eOK = 0,
      eWorldOpen = 30001,
      eWorldClosed = 30002,
      eNoNameSpecified = 30003,
      eCannotPlaySound = 30004,
      eTriggerNotFound = 30005,
      eTriggerAlreadyExists = 30006,
      eAliasNotFound = 30013,
      eTimerNotFound = 30017,
      eVariableNotFound = 30046,
      eOptionOutOfRange = 30024,
    }
    error_desc = error_desc or {}

    -- Output ----------------------------------------------------------------
    function Note(text)
      proteles.echo(text == nil and "" or tostring(text))
    end

    -- ColourNote(fore, back, text, fore2, back2, text2, ...). Per-segment
    -- colours within one line are not yet supported (single styled run): the
    -- segment texts are concatenated and the first triplet's colours applied.
    function ColourNote(...)
      local args = {...}
      local text = ""
      for i = 3, #args, 3 do
        if args[i] ~= nil then text = text .. tostring(args[i]) end
      end
      -- An empty colour string means "default" — pass nil, not "".
      local fore = (args[1] ~= nil and args[1] ~= "") and args[1] or nil
      local back = (args[2] ~= nil and args[2] ~= "") and args[2] or nil
      proteles.note(text, fore, back)
    end
    ColourTell = ColourNote
    function Tell(text)
      proteles.echo(text == nil and "" or tostring(text))
    end

    -- Sending ---------------------------------------------------------------
    function Send(text) proteles.send(tostring(text)); return error_code.eOK end
    function SendNoEcho(text) proteles.sendNoEcho(tostring(text)); return error_code.eOK end
    function Execute(text) proteles.execute(tostring(text)); return error_code.eOK end

    -- Variables -------------------------------------------------------------
    function GetVariable(name) return proteles.getVar(name) end
    function SetVariable(name, value)
      proteles.setVar(name, value == nil and "" or tostring(value))
      return error_code.eOK
    end
    function DeleteVariable(name) proteles.deleteVar(name); return error_code.eOK end
    function GetPluginVariable(id, name) return proteles.getPluginVar(id, name) end

    -- Introspection ---------------------------------------------------------
    function GetInfo(n) return proteles.info(n) end
    function GetPluginID() return proteles.pluginID() end

    -- Inter-plugin ----------------------------------------------------------
    -- MUSHclient CallPlugin returns (status, results...); we report eOK and
    -- forward the callee's return values.
    function CallPlugin(id, fn, ...) return error_code.eOK, proteles.call(fn, ...) end
    function BroadcastPlugin(msg, text)
      proteles.broadcast(msg, text); return error_code.eOK
    end

    -- Automations (name-based enable lands with the XML loader) -------------
    function EnableTrigger(name, flag) return error_code.eOK end
    function EnableTimer(name, flag) return error_code.eOK end
    function EnableGroup(name, flag) return error_code.eOK end

    -- String helpers MUSHclient exposes globally ---------------------------
    function Trim(s)
      if s == nil then return "" end
      return (tostring(s):gsub("^%s*(.-)%s*$", "%1"))
    end
    """
}
