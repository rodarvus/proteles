import CLua
import Foundation

/// The per-fire globals a trigger's script body reads: MUSHclient's
/// `matches`/`named` wildcard tables and the `styles` colour-run array (its
/// 4th script argument). Split out of ``LuaRuntime`` to keep its body within
/// the type-length budget.
extension LuaRuntime {
    /// Set the `matches` (0-based) + `named` globals from trigger captures.
    /// Named captures also go on `matches` by name (MUSHclient's wildcards
    /// table carries both, read as `wildcards.<name>`).
    func setMatchGlobals(_ captures: [String], _ named: [String: String]) {
        lua_createtable(state, Int32(captures.count), Int32(named.count))
        for (index, value) in captures.enumerated() {
            lua_pushstring(state, value)
            lua_rawseti(state, -2, Int32(index))
        }
        for (key, value) in named {
            lua_pushstring(state, value)
            lua_setfield(state, -2, key)
        }
        clua_setglobal(state, "matches")

        lua_createtable(state, 0, Int32(named.count))
        for (key, value) in named {
            lua_pushstring(state, value)
            lua_setfield(state, -2, key)
        }
        clua_setglobal(state, "named")
    }

    /// Set the `styles` global — MUSHclient's 4th trigger argument: a 1-based
    /// array of the matched line's colour runs, each `{text, textcolour,
    /// backcolour, style, length}` (colours BGR-packed ints). Always set (empty
    /// → `{}`) so a trigger body's `styles or {}` never iterates nil — S&D's
    /// `scan_mob`/`consider_trigger` do `ipairs(styles)` to re-render the line.
    func setStyleGlobal(_ styles: [ScriptStyleRun]) {
        lua_createtable(state, Int32(styles.count), 0)
        for (index, run) in styles.enumerated() {
            lua_createtable(state, 0, 5)
            lua_pushstring(state, run.text)
            lua_setfield(state, -2, "text")
            lua_pushnumber(state, Double(run.textColour))
            lua_setfield(state, -2, "textcolour")
            lua_pushnumber(state, Double(run.backColour))
            lua_setfield(state, -2, "backcolour")
            lua_pushnumber(state, 0)
            lua_setfield(state, -2, "style")
            lua_pushnumber(state, Double(run.text.utf8.count))
            lua_setfield(state, -2, "length")
            lua_rawseti(state, -2, Int32(index + 1))
        }
        clua_setglobal(state, "styles")
    }
}
