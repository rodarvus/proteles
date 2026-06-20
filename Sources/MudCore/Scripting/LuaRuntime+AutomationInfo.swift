import CLua
import Foundation

/// The synchronous trigger/alias/timer introspection world-API
/// (`GetTriggerInfo`/`GetTimerInfo`/`GetAliasInfo`, the `Get*List` family, and
/// `GetPluginTriggerList`), answered from the runtime's ``automationSnapshot``
/// mirror. ``ScriptEngine`` keeps the mirror current via ``setAutomationSnapshot``
/// after every automation change, so these reads never cross the actor boundary
/// — the same arrangement that backs the output-buffer queries.
extension LuaRuntime {
    /// Replace the introspection mirror. Isolated (called with `await` from
    /// ``ScriptEngine``), so the snapshot is only ever written on this actor's
    /// executor — the nonisolated readers below run inside `lua_pcall` on the
    /// same executor, so there's no concurrent access (mirrors ``recordOutputLine``).
    func setAutomationSnapshot(_ snapshot: AutomationSnapshot) {
        automationSnapshot = snapshot
    }

    /// Dispatch an introspection host call to the right reader. Reached via
    /// ``queryValue``'s default (so that switch gains no branch); a non-
    /// introspection function returns `[]`.
    nonisolated func automationValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .triggerInfo, .aliasInfo, .timerInfo: automationInfoValue(function, arguments)
        case .triggerOption, .aliasOption, .timerOption: automationOptionValue(function, arguments)
        case .pluginTriggerInfo: pluginTriggerInfoValue(arguments)
        case .triggerList, .aliasList, .timerList, .pluginTriggerList:
            automationListValue(function, arguments)
        default: []
        }
    }

    /// `proteles.triggerInfo`/`timerInfo`/`aliasInfo(name, infoType)` → the field
    /// value, or `nil` for an unknown name/field (MUSHclient `VT_EMPTY`).
    nonisolated func automationInfoValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        let name = Self.objectName(Self.argString(arguments, 0))
        let infoType = Int(Self.argDouble(arguments, 1))
        switch function {
        case .triggerInfo:
            let record = automationSnapshot.triggers.first { $0.name?.lowercased() == name }
            return [record?.info(infoType) ?? .nil]
        case .aliasInfo:
            let record = automationSnapshot.aliases.first { $0.name?.lowercased() == name }
            return [record?.info(infoType) ?? .nil]
        case .timerInfo:
            let record = automationSnapshot.timers.first { $0.name?.lowercased() == name }
            return [record?.info(infoType, now: Date()) ?? .nil]
        default:
            return [.nil]
        }
    }

    /// `proteles.triggerOption`/`aliasOption`/`timerOption(name, option)` → the
    /// option's value, or `nil` for an unknown name/option (MUSHclient VT_EMPTY).
    /// MUSHclient lower-cases and trims the option name (`MakeLower`/`Trim*`).
    nonisolated func automationOptionValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        let name = Self.objectName(Self.argString(arguments, 0))
        let option = Self.argString(arguments, 1).trimmingCharacters(in: .whitespaces).lowercased()
        switch function {
        case .triggerOption:
            let record = automationSnapshot.triggers.first { $0.name?.lowercased() == name }
            return [record?.option(option) ?? .nil]
        case .aliasOption:
            let record = automationSnapshot.aliases.first { $0.name?.lowercased() == name }
            return [record?.option(option) ?? .nil]
        case .timerOption:
            let record = automationSnapshot.timers.first { $0.name?.lowercased() == name }
            return [record?.option(option) ?? .nil]
        default:
            return [.nil]
        }
    }

    /// `proteles.pluginTriggerInfo(pluginID, name, infoType)` — `GetTriggerInfo`
    /// scoped to a trigger *owned by* `pluginID` (MUSHclient `GetPluginTriggerInfo`,
    /// which switches plugin context then calls `GetTriggerInfo`). An unknown
    /// plugin/trigger/field yields `nil`.
    nonisolated func pluginTriggerInfoValue(_ arguments: [LuaValue]) -> [LuaValue] {
        let pluginID = Self.argString(arguments, 0)
        let name = Self.objectName(Self.argString(arguments, 1))
        let infoType = Int(Self.argDouble(arguments, 2))
        let record = automationSnapshot.triggers.first {
            $0.owner == pluginID && $0.name?.lowercased() == name
        }
        return [record?.info(infoType) ?? .nil]
    }

    /// `proteles.triggerList`/`timerList`/`aliasList()` (the calling plugin's
    /// items) and `proteles.pluginTriggerList(id)` → a 1-indexed Lua array of
    /// names, or `nil` when there are none — matching MUSHclient, whose
    /// `Get*List` returns an empty VARIANT (→ nil) rather than an empty array.
    nonisolated func automationListValue(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        let names: [String] = switch function {
        case .triggerList: automationSnapshot.triggerNames(ownedBy: pluginContext.pluginID)
        case .aliasList: automationSnapshot.aliasNames(ownedBy: pluginContext.pluginID)
        case .timerList: automationSnapshot.timerNames(ownedBy: pluginContext.pluginID)
        case .pluginTriggerList: automationSnapshot.triggerNames(ownedBy: Self.argString(arguments, 0))
        default: []
        }
        return names.isEmpty ? [.nil] : [pushNameArray(names)]
    }

    /// Build a 1-indexed Lua array of `names` on the stack and hand it back
    /// through the registry-ref bridge (``LuaValue`` has no table case), as
    /// ``variableList`` does for `GetVariableList`.
    nonisolated func pushNameArray(_ names: [String]) -> LuaValue {
        lua_createtable(state, Int32(names.count), 0)
        for (index, name) in names.enumerated() {
            lua_pushstring(state, name)
            lua_rawseti(state, -2, Int32(index + 1))
        }
        let ref = luaL_ref(state, LUA_REGISTRYINDEX) // pops the table, stores it
        noteTransientRef(ref)
        return .functionRef(ref)
    }

    /// MUSHclient `CheckObjectName`: trigger/alias/timer lookups trim surrounding
    /// whitespace and lower-case the name before matching. Names are stored
    /// already-normalised by the loader, so this just normalises the *query*.
    static func objectName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
