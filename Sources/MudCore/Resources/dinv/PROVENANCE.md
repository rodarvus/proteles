# dinv — provenance

These files are the **dinv** inventory-manager plugin for Aardwolf, vendored
verbatim and run through Proteles' MUSHclient compatibility shim (D-32).

- **Upstream:** https://github.com/rodarvus/dinv (the author's own plugin)
- **Vendored version:** 3.0102 (see `dinv.manifest`)
- **License:** MIT (see `LICENSE`) — author: Durel (original `aard_inventory`),
  Rodarvus (the v3.x SQLite/modular fork). Bundling is unambiguous: MIT, and the
  Proteles author is the fork maintainer.

dinv is a fork of Durel's `aard_inventory`, modernized with a modular Lua
codebase (`dinv.xml` bootstraps `dinv_init.lua`, which `dofile`s 20 modules),
SQLite-backed per-character storage, and a manifest-based updater.

## How Proteles runs it

dinv is loaded **verbatim** through the existing 3rd-party compat shim
(`mush.lua` + per-plugin environment), not a bespoke native host — it has **no
miniwindow** (pure text output), so no SwiftUI panel bridge is needed (contrast
Search-and-Destroy, D-28/D-30). Its modules are registered with the runtime's
module loader by basename so `dofile(dir .. "dinv_X.lua")` resolves from the
bundle; its `require`s (wait/check/serialize/tprint/gmcphelper/json) and the
inert `async` stub are already provided by the shim.

The GitHub self-updater (`dbot.remote`, the only `async`/`io` user) is inert:
Proteles vendors dinv and updates it with the app, so `dinv version
check/update` is a no-op here.

## Local modifications

These files are vendored *near*-verbatim; the only divergence from upstream is
a small set of removed user-command **aliases** in `dinv.xml`. The underlying
Lua handlers are left untouched (so re-syncing upstream is a matter of
re-deleting these alias blocks):

- **`dinv version`** (check / changelog / update confirm) — removed. The
  handlers fetch over HTTP from GitHub, which the native host doesn't provide,
  and in-client self-update isn't a Proteles flow (the app ships dinv).
- **`dinv backup`** (list / create / delete / restore) — removed. Manual
  backup/restore is an admin flow we don't surface. The *automatic* pre-build
  backup (`dbot.backup.preBuild`) is internal and still runs.
- **`dinv migrate`** (confirm) — removed. DB-format migration is an admin flow
  we don't surface.

`dinv reload` is kept and works: it calls `ReloadPlugin(GetPluginID())` via the
shim's `DoAfterSpecial(…, sendto.script)`, which the host routes to a clean
unload + reload of the bundled plugin.
