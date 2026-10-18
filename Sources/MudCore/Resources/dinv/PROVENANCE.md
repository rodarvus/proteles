# dinv — provenance

These files are the **dinv** inventory-manager plugin for Aardwolf, vendored
verbatim and run through Proteles' MUSHclient compatibility shim (D-32).

- **Upstream:** https://github.com/rodarvus/dinv (the author's own plugin),
  tracked as the repo submodule at `plugins/dinv`.
- **Vendored version:** 3.0130 (`d752b73`).
- **License:** MIT (see `LICENSE`) — author: Durel (original `aard_inventory`),
  Rodarvus (the v3.x SQLite/modular fork). Bundling is unambiguous: MIT, and the
  Proteles author is the fork maintainer.

**Re-vendoring is reproducible and CI-guarded (GitHub #67).**
`scripts/vendor-plugins.sh` copies the runtime files verbatim from the submodule
(LF line endings, as upstream) and applies the Proteles-local edits in
`scripts/vendor-patches/dinv.patch`. `scripts/vendor-plugins.sh --check` runs in
CI and fails if this copy drifts from the pinned submodule + patch. To pick up a
new release: bump the submodule, re-run the script (re-derive the patch if a hunk
no longer applies), update the version/commit above, then rebuild + test.

dinv is a fork of Durel's `aard_inventory`, modernized with a modular Lua
codebase (`dinv.xml` bootstraps `dinv_init.lua`, which loads its Lua modules),
SQLite-backed per-character storage, and a manifest-based updater.

## How Proteles runs it

dinv is loaded **verbatim** through the existing 3rd-party compat shim
(`mush.lua` + per-plugin environment), not a bespoke native host — it has **no
miniwindow** (pure text output), so no SwiftUI panel bridge is needed (contrast
Search-and-Destroy, D-28/D-30). Its modules are registered with the runtime's
module loader by basename so `dofile(dir .. "dinv_X.lua")` resolves from the
bundle; its `require`s (check/serialize/tprint/gmcphelper/json) and the
inert `async` stub are already provided by the shim.

The GitHub self-updater (`dbot.remote`, the only `async`/`io` user) is inert:
Proteles vendors dinv and updates it with the app, so `dinv version
check/update` is a no-op here.

## Local modifications

These files are vendored *near*-verbatim. The exact divergence from upstream is
captured in **`scripts/vendor-patches/dinv.patch`** (applied by
`scripts/vendor-plugins.sh`), so re-syncing a new upstream release is mechanical:
re-run the script, and re-derive the patch only if a hunk no longer applies. The
edits are a small set of removed user-command **aliases** in `dinv.xml` (the
underlying Lua handlers are left untouched) plus one `dinv_dbot.lua` tweak. (The
flat per-character DB path via `proteles.databaseDir()` is **no longer a local
edit** — upstream adopted it natively as of this version.)

Removed aliases (`dinv.xml`):

- **`dinv version`** (check / changelog / update confirm) — removed. The
  handlers fetch over HTTP from GitHub, which the native host doesn't provide,
  and in-client self-update isn't a Proteles flow (the app ships dinv).
- **`dinv backup`** (list / create / delete / restore) — removed. Manual
  backup/restore is an admin flow we don't surface. The *automatic* pre-build
  backup (`dbot.backup.preBuild`) is also disabled below.
- **`dinv migrate`** (confirm) — removed. DB-format migration is an admin flow
  we don't surface.

`dinv reload` is kept and works: it calls `ReloadPlugin(GetPluginID())` via the
shim's `DoAfterSpecial(…, sendto.script)`, which the host routes to a clean
unload + reload of the bundled plugin.

The remaining local Lua edit is in `dinv_dbot.lua`:

- **`dbot.backup.preBuild()`** — neutralized to a no-op. It otherwise creates an
  automatic pre-build backup by copying the SQLite DB file via Lua `io`
  (`copyFile`), but the sandbox excludes `io`, so once the DB has items the
  build would error with `attempt to index global 'io'`. Backups are disabled
  anyway (the `dinv backup` command is removed), so skipping is consistent. The
  other `io` users in dinv (the GitHub version-updater and `dinv_migrate`) sit
  behind the removed `version`/`migrate` commands and aren't reached.

The earlier D-77 wish-parser patch is superseded by upstream's narrow report
parser, armed before dispatch. It suppresses recognized report lines while
leaving unrelated output visible, and publishes wishes only after a valid
header/footer and the coordinator's unique completion fence. No fixed wishlist
or stat-bonus echo is sent. The September 16 development snapshot also reserves
complete equipment/portal workflows and retains exact canceled-fence gags.

The accompanying Proteles host change removes the old 80-line wishlist gag that
waited for `DINV wish list fence`. It must ship together with these resources;
the real-session tests verify the plugin's parser and unrelated output without
that host fallback.
