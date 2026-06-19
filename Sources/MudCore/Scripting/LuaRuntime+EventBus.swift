import CLua
import Foundation

extension LuaRuntime {
    /// The event-bus / RPC registration & firing functions (no return value).
    nonisolated func registerOrRaise(_ function: HostFunction, _ arguments: [LuaValue]) {
        switch function {
        case .onEvent:
            if let ref = Self.argFunctionRef(arguments, 1) {
                eventHandlers[Self.argString(arguments, 0), default: []].append(
                    OwnedRegistryRef(ref: claim(ref), owner: currentRegistrationOwner())
                )
            }
        case .raiseEvent:
            invokeHandlers(
                (eventHandlers[Self.argString(arguments, 0)] ?? []).map(\.ref),
                payload: Array(arguments.dropFirst())
            )
        case .onBroadcast:
            if let ref = Self.argFunctionRef(arguments, 0) {
                broadcastHandlers.append(
                    OwnedRegistryRef(ref: claim(ref), owner: currentRegistrationOwner())
                )
            }
        case .broadcast:
            invokeHandlers(broadcastHandlers.map(\.ref), payload: arguments)
        case .export:
            if let ref = Self.argFunctionRef(arguments, 1) {
                let name = Self.argString(arguments, 0)
                if let previous = exportedFunctions[name] {
                    luaL_unref(state, LUA_REGISTRYINDEX, previous.ref)
                }
                exportedFunctions[name] = OwnedRegistryRef(
                    ref: claim(ref),
                    owner: currentRegistrationOwner()
                )
            }
        default:
            break
        }
    }

    /// Remove long-lived `proteles.onEvent`/`onBroadcast`/`export` refs owned by
    /// a plugin being unloaded. These refs live outside the plugin env table, so
    /// `clearPluginEnvironment` alone cannot release them.
    func clearPluginRegistrations(_ pluginID: String) {
        for (event, handlers) in eventHandlers {
            var kept: [OwnedRegistryRef] = []
            for handler in handlers {
                if handler.owner == pluginID {
                    luaL_unref(state, LUA_REGISTRYINDEX, handler.ref)
                } else {
                    kept.append(handler)
                }
            }
            if kept.isEmpty {
                eventHandlers[event] = nil
            } else {
                eventHandlers[event] = kept
            }
        }

        broadcastHandlers.removeAll { handler in
            guard handler.owner == pluginID else { return false }
            luaL_unref(state, LUA_REGISTRYINDEX, handler.ref)
            return true
        }

        for (name, exported) in exportedFunctions where exported.owner == pluginID {
            luaL_unref(state, LUA_REGISTRYINDEX, exported.ref)
            exportedFunctions[name] = nil
        }
    }

    /// Record a function ref that will be freed at run-end unless claimed.
    nonisolated func noteTransientRef(_ ref: Int32) {
        transientRefs.append(ref)
    }

    /// Mark a transient ref as owned (stored long-term), so it isn't freed at
    /// run-end. Returns the same ref. Pair with `luaL_unref` when done.
    nonisolated func claim(_ ref: Int32) -> Int32 {
        transientRefs.removeAll { $0 == ref }
        return ref
    }

    /// Free every still-unclaimed function ref created during this run.
    nonisolated func releaseTransientRefs() {
        for ref in transientRefs {
            luaL_unref(state, LUA_REGISTRYINDEX, ref)
        }
        transientRefs.removeAll(keepingCapacity: true)
    }

    /// Call each handler ref with `payload`, discarding results. Handler
    /// errors are surfaced as a red note rather than aborting the caller.
    nonisolated func invokeHandlers(_ refs: [Int32], payload: [LuaValue]) {
        for ref in refs {
            lua_rawgeti(state, LUA_REGISTRYINDEX, ref)
            for value in payload {
                luaPushValue(state, value)
            }
            if protectedCall(nargs: Int32(payload.count), nresults: 0) != 0 {
                let message = "Lua event error: \(Self.popMessage(state))"
                effects.append(.note(text: message, foreground: "red", background: nil))
                effects.append(contentsOf: sourceContextEffects(forError: message))
            }
        }
    }

    /// Call an exported function ref with `payload`, returning its results.
    nonisolated func invokeFunction(_ ref: Int32, payload: [LuaValue]) -> [LuaValue] {
        let base = lua_gettop(state)
        lua_rawgeti(state, LUA_REGISTRYINDEX, ref)
        for value in payload {
            luaPushValue(state, value)
        }
        if protectedCall(nargs: Int32(payload.count), nresults: LUA_MULTRET) != 0 {
            let message = "Lua call error: \(Self.popMessage(state))"
            effects.append(.note(text: message, foreground: "red", background: nil))
            effects.append(contentsOf: sourceContextEffects(forError: message))
            lua_settop(state, base)
            return []
        }
        let resultCount = lua_gettop(state) - base
        var results: [LuaValue] = []
        if resultCount > 0 {
            for index in (base + 1)...(base + resultCount) {
                results.append(luaReadValue(state, index))
            }
        }
        lua_settop(state, base)
        return results
    }

    private nonisolated func currentRegistrationOwner() -> String? {
        currentVariableScope == "_user" ? nil : currentVariableScope
    }
}
