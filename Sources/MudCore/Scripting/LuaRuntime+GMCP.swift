import CLua
import Foundation

/// Projecting GMCP into the Lua side: a live `proteles.gmcp` table plus
/// per-level `gmcp.*` events, modelled on Mudlet (PLAN.md §8.6).
extension LuaRuntime {
    /// Project one GMCP message into the live `proteles.gmcp` table and fire
    /// the per-level `gmcp.*` events for it, returning any effects the
    /// handlers recorded.
    ///
    /// Mirrors Mudlet: the dotted package name walks nested tables (so
    /// `char.vitals` becomes `proteles.gmcp.char.vitals`), the JSON payload
    /// is decoded to native Lua values (numbers stay numbers), and one event
    /// is raised per path level — `gmcp.char` then `gmcp.char.vitals` — each
    /// carrying the full dotted package name. The leaf is replaced wholesale
    /// (the typed ``GMCPStateStore`` remains the source of truth; this is a
    /// projected view). Never throws — a malformed payload simply stores an
    /// empty table.
    @discardableResult
    public func applyGMCP(package: String, json: String) -> [ScriptEffect] {
        effects.removeAll(keepingCapacity: true)
        defer { releaseTransientRefs() }
        let components = package.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return effects }
        updateGMCPTable(components: components, json: json)
        raiseGMCPEvents(package: package, components: components)
        return effects
    }

    /// Walk `components` under `proteles.gmcp`, creating intermediate tables
    /// as needed, and set the leaf to the decoded JSON value.
    private func updateGMCPTable(components: [String], json: String) {
        let value = try? JSONSerialization.jsonObject(
            with: Data(json.utf8), options: [.fragmentsAllowed]
        )

        clua_getglobal(state, "proteles") // [proteles]
        lua_getfield(state, -1, "gmcp") // [proteles, gmcp]
        lua_remove(state, -2) // [gmcp]

        // Descend to the leaf's parent table, creating tables on the way.
        for component in components.dropLast() {
            lua_getfield(state, -1, component) // [.., child?]
            if lua_type(state, -1) != LUA_TTABLE {
                clua_pop(state, 1)
                lua_createtable(state, 0, 0) // [.., newChild]
                lua_pushvalue(state, -1) // [.., newChild, newChild]
                lua_setfield(state, -3, component) // parent[component] = newChild
            }
            lua_remove(state, -2) // drop parent; [child]
        }

        // A malformed/absent payload becomes an empty table, so the leaf is
        // always present as a table (setting a nil field would delete it).
        if let value {
            pushJSONValue(value) // [parent, value]
        } else {
            lua_createtable(state, 0, 0)
        }
        lua_setfield(state, -2, components[components.count - 1]) // parent[leaf] = value
        clua_pop(state, 1) // pop parent
    }

    /// Recursively push a decoded-JSON Foundation value onto the Lua stack
    /// as a native Lua value (objects → string-keyed tables, arrays →
    /// 1-based tables, numbers stay numbers, booleans stay booleans).
    private func pushJSONValue(_ value: Any?) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                lua_pushboolean(state, number.boolValue ? 1 : 0)
            } else {
                lua_pushnumber(state, number.doubleValue)
            }
        case let string as String:
            lua_pushstring(state, string)
        case let array as [Any]:
            lua_createtable(state, Int32(array.count), 0)
            for (index, element) in array.enumerated() {
                pushJSONValue(element)
                lua_rawseti(state, -2, Int32(index + 1))
            }
        case let dictionary as [String: Any]:
            lua_createtable(state, 0, Int32(dictionary.count))
            for (key, element) in dictionary {
                pushJSONValue(element)
                lua_setfield(state, -2, key)
            }
        default:
            lua_pushnil(state) // null / unrepresentable
        }
    }

    /// Fire `gmcp.<level>` for each cumulative path level (Mudlet
    /// convention), passing the full dotted package name as the payload.
    private func raiseGMCPEvents(package: String, components: [String]) {
        var name = "gmcp"
        for component in components {
            name += "." + component
            invokeHandlers(eventHandlers[name] ?? [], payload: [.string(package)])
        }
    }
}
