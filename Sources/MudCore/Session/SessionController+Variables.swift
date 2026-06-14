import Foundation

/// Host-side variable API backing the Scripts window's Variables tab (#69).
///
/// Reads merge the on-disk ``VariableStore`` with the live runtimes — during
/// play the runtime is the source of truth (``VariableStore`` only mirrors it),
/// so the editor must show what the runtime actually holds. Writes hot-update
/// the runtime that owns the scope and then reuse ``persistVariablesIfDirty()``
/// to flush the change to disk — the same update-then-persist contract the
/// trigger/alias editors use, so an edit takes effect immediately and survives
/// relaunch without a reconnect.
///
/// Scope routing: `_user` and every generic plugin scope live in the one
/// ``ScriptEngine`` runtime; only Search-and-Destroy has its own runtime, so its
/// `pluginID` scope routes there. With no runtime at all (headless/tests) the
/// store is written directly.
public extension SessionController {
    /// Every variable scope for the editor: the on-disk store overlaid with
    /// each live runtime's current values (live wins on conflict).
    func variableScopes() async -> [String: [String: String]] {
        var result = await variableStore?.scopes ?? [:]
        if let scriptEngine {
            for (scope, vars) in await scriptEngine.variablesSnapshot() {
                result[scope] = vars
            }
        }
        if let searchAndDestroy {
            for (scope, vars) in await searchAndDestroy.variablesSnapshot() {
                result[scope] = vars
            }
        }
        return result
    }

    /// Set (or create) a variable, hot-updating the runtime that owns the scope
    /// and persisting through the store.
    func setVariable(scope: String, name: String, value: String) async {
        if scope == SearchAndDestroyHost.pluginID, let searchAndDestroy {
            await searchAndDestroy.setVariableValue(scope: scope, name: name, value: value)
        } else if let scriptEngine {
            await scriptEngine.setVariableValue(scope: scope, name: name, value: value)
        } else {
            await writeStoreScope(scope) { $0[name] = value }
            return
        }
        await persistVariablesIfDirty()
    }

    /// Delete a variable from a scope, hot-updating the owning runtime and
    /// persisting the removal.
    func deleteVariable(scope: String, name: String) async {
        if scope == SearchAndDestroyHost.pluginID, let searchAndDestroy {
            await searchAndDestroy.deleteVariableValue(scope: scope, name: name)
        } else if let scriptEngine {
            await scriptEngine.deleteVariableValue(scope: scope, name: name)
        } else {
            await writeStoreScope(scope) { $0[name] = nil }
            return
        }
        await persistVariablesIfDirty()
    }

    /// Rename a variable within a scope: delete the old key, set the new one
    /// (carrying the value over). A no-op when the name is unchanged.
    func renameVariable(scope: String, from oldName: String, to newName: String, value: String) async {
        guard oldName != newName else { return }
        await deleteVariable(scope: scope, name: oldName)
        await setVariable(scope: scope, name: newName, value: value)
    }

    /// Write one scope to the store directly — the no-runtime fallback so the
    /// editor still works headless (and in tests). Live sessions never take
    /// this path (the runtime is always present).
    private func writeStoreScope(_ scope: String, _ mutate: (inout [String: String]) -> Void) async {
        guard let variableStore else { return }
        var vars = await variableStore.scopes[scope] ?? [:]
        mutate(&vars)
        try? await variableStore.update(scope: scope, variables: vars)
    }
}
