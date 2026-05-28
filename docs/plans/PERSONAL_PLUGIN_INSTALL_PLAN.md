# Installing personal plugins (local path / arbitrary URL)

> Plan deliverable (no code). A capability to load **personal or third-party
> MUSHclient plugins** that aren't bundled with Proteles — from a **local
> folder** or an **arbitrary URL** — without adding them to the app's shipped
> bundle. This is the general mechanism by which a user runs their own plugins
> (or any community plugin) privately, on their own machine.

## Why
Proteles bundles a curated native set + runs imported MUSHclient XML plugins via
the compat shim. But a user may have their own plugins (or want a community one)
that should **not** ship in the app and should **not** be published anywhere —
they live only on the user's machine / their own repo. We need a first-class way
to point Proteles at such a plugin and run it through the shim.

## What we already have to build on
- The MUSHclient XML plugin loader + the `mush.lua` compat shim (runs arbitrary
  3rd-party plugins in per-plugin sandboxed Lua environments).
- The Plugins window (⇧⌘P) with guided import + a compatibility report.
- The **download-on-request installer** pattern shipped for Search & Destroy
  (`SearchAndDestroyInstaller`: URLSession download + `ditto` extract into the
  per-profile app-support dir, attached live). That is exactly the URL path,
  generalised.
- lsqlite3 sandbox + per-character SQLite paths (so DB-backed plugins work).

## Proposed capability

1. **Load from a local folder** — a "Add Local Plugin…" action in the Plugins
   window: pick a folder/`.xml`; Proteles loads it via the shim, resolving its
   `dofile`/`require` modules relative to that folder (basename resolution, as
   the dinv modules already do). The plugin stays where it is on disk; nothing is
   copied into the app bundle. Per-world enable/disable + persistence as usual.
2. **Install from a URL** — generalise `SearchAndDestroyInstaller` into a reusable
   installer: given a URL (zip or raw `.xml`), download to the per-profile
   plugins dir, extract, register, attach live. The user supplies the URL; the
   acknowledgement/consent flow matches S&D's (third-party code, your machine,
   your responsibility).
3. **Privacy guarantees** — personal plugins loaded this way are never added to
   the Proteles repo or any release artifact. They live in the user's own
   location (a folder or their own repo behind the URL). Proteles only records a
   reference (path/URL) in the per-world profile, which is local user data.

## Shim viability (general finding)
From auditing large real-world Aardwolf plugins: the typical heavy plugin
(thousands of lines, SQLite-backed, GMCP-driven) is **shim-viable** — the one
hard blocker is MUSHclient **miniwindows** (a Windows canvas API we replace with
native panels), and most non-UI plugins don't use them. They rely on APIs the
shim already supports and that the dinv port hardened: `EnableTriggerGroup`,
`DoAfterSpecial`, `Set/GetVariable`, `AddTriggerEx`, `sqlite3`, `save_state`,
`gmcphelper`. So loading a personal plugin is mostly: point at it, run it,
verify live (transcript-driven), close any small shim gap it surfaces.

For a plugin that uses an Aardwolf room/inventory **tag** option, note we now
have `setAardwolfTagOption` (the option-102 subneg) from the Help work, so
enabling those tags is a known, cheap pattern.

## Phases
1. **Load-from-local-folder** in the Plugins window (the lowest-friction path
   for personal plugins) + per-world reference persistence.
2. Generalise the S&D installer into a **reusable URL installer** + an
   acknowledgement flow.
3. Polish: a "manage my plugins" list (local + URL sources), update/refresh,
   remove.

## Decisions for the user
1. **Local-folder load** (recommended first — simplest, keeps personal plugins
   entirely on your machine) vs URL install vs both?
2. Where should Proteles remember the reference — per-world profile (local) only?
   (Recommended; never in any shared/published artifact.)
3. Should a personal plugin's SQLite DB live under the same per-character sandbox
   root as the bundled plugins? (Recommended — consistent + sandboxed.)

## Effort
Low–medium. The shim + loader + installer pattern already exist; this is mostly a
Plugins-window action + a reference-persistence path + reusing the S&D installer.
Per-plugin "does it run?" is live verification on your side.
