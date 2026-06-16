import Foundation

/// Deferred plugin activation. Rather than loading MUSHclient plugins at
/// world-load (during login + MOTD, where their init-time server probes like
/// `slist` or `cp info` fail), we **arm** the loads and run them only once the
/// character is in-game — the first `char.status` with state ≥ 3, the signal
/// dinv has always used. Activation loads the plugins (their `OnPluginInstall`)
/// once, then fires `OnPluginConnect`; a fallback timer covers a stuck login or
/// a MUD that never sends state 3.
extension SessionController {
    /// How long to wait for the in-game signal before activating anyway.
    /// Generous: Aardwolf sends an in-game `char.status` within seconds of login,
    /// so this only matters as insurance.
    static let pluginActivationFallback: Duration = .seconds(45)

    /// Record the initial plugin set to load on activation (called at world-load
    /// instead of loading immediately). Re-arming resets ``pluginsLoaded`` so a
    /// freshly-selected world reloads its plugins on the next in-game signal.
    public func armInitialPlugins(directories: [URL], character: String, levelDBDirectory: String?) {
        pendingInitialPluginDirectories = directories
        pendingInitialPluginCharacter = character
        pendingLevelDBDirectory = levelDBDirectory
        pluginsLoaded = false
    }

    /// Activate plugins for this connection: load the armed set once (their
    /// `OnPluginInstall`), then fire `OnPluginConnect`. Idempotent — driven by
    /// both the in-game signal and the fallback timer; the load runs once per
    /// world (plugins persist across reconnects), the connect once per connection.
    func activatePluginsIfNeeded() async {
        guard connection != nil, scriptEngine != nil else { return }
        pluginActivationFallbackTask?.cancel()
        pluginActivationFallbackTask = nil

        if !pluginsLoaded {
            pluginsLoaded = true
            await loadDeferredInitialPlugins()
        }
        if !pluginsConnectFired, let scriptEngine {
            pluginsConnectFired = true
            await replayGMCPToLoadedPlugins()
            await applyScriptEffects(scriptEngine.connectPlugins())
        }
        // Loads/connect commonly arm timers + schedule probes; re-arm the loop.
        await rearmTimerLoopIfScriptScheduled()
        await persistVariablesIfDirty()
    }

    /// Re-deliver the GMCP that arrived *before* the deferred plugins loaded, so
    /// a late-loading plugin initialises from current state (e.g. `char.base`'s
    /// `tier`/`level`, used to compute the effective level). Plugins are deferred
    /// to the first in-game `char.status` (D-74), but `char.base` and friends
    /// arrive earlier — so an event-driven plugin (one that recomputes on the
    /// `char.base` broadcast) would otherwise never see them, unlike MUSHclient
    /// where plugins load at connect and catch every broadcast. `char.status` is
    /// excluded: the in-game one that triggered activation is delivered fresh
    /// right after, by the caller. `applyGMCP` re-fires `OnPluginBroadcast` to
    /// every loaded plugin (proteles.gmcp is already current); the subnegotiation
    /// covers plugins reading the option-201 path (dinv's config detection).
    private func replayGMCPToLoadedPlugins() async {
        guard let scriptEngine else { return }
        let priority = ["char.base", "char.maxstats", "char.worth", "char.vitals", "room.info"]
        let ordered = priority.filter { latestGMCPByPackage[$0] != nil }
            + latestGMCPByPackage.keys.filter { !priority.contains($0) && $0 != "char.status" }.sorted()
        for package in ordered where package != "char.status" {
            guard let json = latestGMCPByPackage[package] else { continue }
            await applyScriptEffects(scriptEngine.applyGMCP(package: package, json: json))
            await applyScriptEffects(scriptEngine.deliverGMCPSubnegotiation(package: package, json: json))
        }
    }

    /// Run the armed initial loads: the enabled library plugins, the bundled
    /// leveldb, and the armed dinv. Each is guarded/idempotent on its own.
    private func loadDeferredInitialPlugins() async {
        if let character = pendingInitialPluginCharacter {
            await activateMapperOverlay(character: character)
        }
        if let character = pendingInitialPluginCharacter, !pendingInitialPluginDirectories.isEmpty {
            await loadPlugins(directories: pendingInitialPluginDirectories, character: character)
        }
        if let levelDBDirectory = pendingLevelDBDirectory {
            await loadBundledLevelDB(dataDirectory: levelDBDirectory)
        }
        // NOTE: dinv is intentionally NOT loaded here. Its init is a fragile
        // one-shot — it runs `inv.init.atActive()` only on the *first* char.base
        // broadcast it sees, and only if the state is active at that instant
        // (else it flips its "initialized" flag and never retries). Loading it
        // inside this simultaneous batch (alongside ~15 other plugins, all
        // sending probes) raced its char.base handling and left it uninitialized
        // (the user had to `dinv reload`). So dinv keeps its own dedicated
        // arming (`armedDinvShouldLoad` → `loadPendingDinv` in `dispatchGMCP`),
        // which already loads it on the in-game char.status with clean timing.
    }

    /// Activate the per-character mapper overlay once the character is known
    /// (D-111). Attaches `Databases/<character>/Aardwolf-personal.db` so the
    /// map shows that character's portals/custom-exits/locks. **Inert until the
    /// shared map has been migrated** (the `personal_split` flag): on an
    /// un-migrated single-file DB `attachPersonalStore` is a guarded no-op, so
    /// behaviour is unchanged until the user runs the migration.
    func activateMapperOverlay(character: String) async {
        guard let mapper,
              let overlay = try? ProtelesPaths.personalMapperDatabaseURL(character: character)
        else { return }
        // Already-split DB → attach silently. Un-migrated DB with personal data
        // → ask the user once (assign to this character) rather than guess.
        if await mapper.needsPersonalMigration() {
            mapperMigrationPromptsContinuation.yield(character)
        } else {
            try? await mapper.attachPersonalStore(at: overlay)
            await pointSearchAndDestroyAtOverlay(overlay)
        }
    }

    /// Run the one-time mapper migration for `character` (D-111), invoked when
    /// the user accepts the prompt: back up the shared map, split this
    /// character's personal data into its overlay, attach it, and point S&D's
    /// direct reads at the overlay too.
    public func migrateMapperPersonal(character: String) async {
        guard let mapper,
              let overlay = try? ProtelesPaths.personalMapperDatabaseURL(character: character),
              let shared = try? ProtelesPaths.mapperDatabaseURL()
        else { return }
        let backup = shared.deletingLastPathComponent()
            .appendingPathComponent("Aardwolf-premigration-backup.db")
        try? await mapper.migratePersonal(overlayURL: overlay, backupURL: backup)
        await pointSearchAndDestroyAtOverlay(overlay)
    }

    /// Point the S&D host's direct mapper-DB reads at `overlay` (D-111). S&D
    /// opens the shared `Aardwolf.db` per-query, so this takes effect on its next
    /// read with no reload; harmless pre-migration (the overlay won't exist yet,
    /// so the merge is skipped). No-op when S&D isn't installed.
    private func pointSearchAndDestroyAtOverlay(_ overlay: URL) async {
        guard let shared = try? ProtelesPaths.mapperDatabaseURL() else { return }
        await searchAndDestroy?.configureMapperOverlay(
            sharedDBPath: shared.path, overlayPath: overlay.path
        )
    }

    /// Arm the fallback that activates plugins if no in-game `char.status`
    /// arrives in time. Replaces any previous timer.
    func schedulePluginActivationFallback() {
        pluginActivationFallbackTask?.cancel()
        pluginActivationFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pluginActivationFallback)
            guard !Task.isCancelled else { return }
            await self?.activatePluginsIfNeeded()
        }
    }
}
