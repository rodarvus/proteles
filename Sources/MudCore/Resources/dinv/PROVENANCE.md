# dinv — provenance

These files are the **dinv** inventory-manager plugin for Aardwolf, vendored
verbatim and run through Proteles' MUSHclient compatibility shim (D-32).

- **Upstream:** https://github.com/rodarvus/dinv (the author's own plugin)
- **Vendored version:** 3.0112 (see `dinv.manifest`)
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

Two more local edits, in `dinv_dbot.lua`:

- **`dbot.wish.setupFn()`** (D-77) — one added line: `EnableTrigger(dbot.wish.
  trigger.itemName, true)`. Upstream arms the omit-from-output wish-item gag only
  when its START trigger matches the `wish list` column header
  (`Base…Cost…Adjustment…Your…Cost…Keyword`). If that header reaches output before
  the START trigger is live — the post-login probe burst, or trigger teardown from
  a mid-probe reload — the gag never arms and the whole list prints (the live
  "wish output ungagged" report). `setupFn` runs inside the safe-exec critical
  section immediately before the command is sent to the mud, so enabling the item
  trigger there gags every wish line regardless of header timing; the fence
  (`dbot.wish.fenceMsg`) still disables it, so it can't over-gag. The START
  trigger is kept as a harmless belt-and-suspenders, so re-syncing upstream is just
  deleting this one line. Proven by `DinvWishGagTests.wishBodyGaggedWhenHeaderUnmatched`
  (with a deliberately non-matching header, the list still gags; reverting the line
  leaks the whole list).
- **`dbot.backup.preBuild()`** — neutralized to a no-op. It otherwise creates an
  automatic pre-build backup by copying the SQLite DB file via Lua `io`
  (`copyFile`), but the sandbox excludes `io`, so once the DB has items the
  build would error with `attempt to index global 'io'`. Backups are disabled
  anyway (the `dinv backup` command is removed), so skipping is consistent. The
  other `io` users in dinv (the GitHub version-updater and `dinv_migrate`) sit
  behind the removed `version`/`migrate` commands and aren't reached.
