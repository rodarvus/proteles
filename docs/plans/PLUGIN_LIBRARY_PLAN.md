# The Plugin Library — one discoverable home for plugins (and, later, scripts)

> Supersedes `PERSONAL_PLUGIN_INSTALL_PLAN.md`. Replaces the split between
> "imported" (copied-in) and "personal" (in-place) plugins with **one**
> mechanism, organised around user journeys, in a **user-visible, hand-editable**
> location. No "personal / private / local" framing anywhere in the UI.

## Why (user journeys)
There is no meaningful difference between a "personal" plugin and an "imported"
MUSHclient plugin — both are just a plugin the user added. What actually differs
is **where it came from**, which decides **how the user updates it**:

1. **Migrating from Windows with a set of plugins** — may get a new version of a
   plugin from a friend → offer "update from a local file".
2. **Uses a plugin straight from GitHub/a URL** → offer a manual "refresh"
   (re-download). No "github" concept in the layout — it's just a plugin.
3. **A multi-file plugin on disk** — a directory of files, or loose files.
4. **Actively develops a plugin** — "hiding" files in the app container is
   hostile (can't point an IDE at them). Files must live somewhere discoverable.

The unifying fix: **every plugin lives in a discoverable, self-contained
directory** the user can navigate to and hand-edit, and later zip up to share.

## The data home
```
~/Documents/Proteles/
  Plugins/
    <Plugin Name>/                  one self-contained, human-named dir
      <plugin>.xml                  the MUSHclient plugin + its .lua modules
      plugin.json                   manifest: mushclient id, name, origin, timestamps
      data/<profile>/               per-character data (Phase B)
        *.db                        SQLite; lsqlite3 sandbox root (Phase B)
        state/                      save_state / SetVariable persistence (Phase B)
  Databases/                        GLOBAL, world-wide DBs (Phase B)
    Aardwolf.db                     mapper (one map of Aardwolf, all characters)
    SnDdb.db                        Search-and-Destroy (area/mob data, all characters)
  (later) Scripts/ , Aliases/ …     same philosophy; out of scope here
```

### Scoping decisions (settled with the user, 2026-05-29)
- **Code is global** (one copy, shared across characters/profiles); **data is
  per-character** under `data/<profile>/`. Enable-state stays per-character.
- **Mapper + S&D DBs are global**, not per-character → `Databases/` (the map and
  the area/mob search are world-wide). **dinv data is per-character** (each
  character has its own inventory) → `Plugins/dinv/data/<profile>/`.
- **Explicit-add only.** Proteles loads only plugins in its registry (written
  when you Add one); a raw folder dropped into `Plugins/` is ignored until added.
  The per-dir `plugin.json` still makes each plugin self-describing for
  hand-editing and future sharing.
- **All refreshes are manual** — the user explicitly triggers re-download /
  re-copy; nothing auto-fetches or polls.
- **No migration.** Fresh start (single user, happy to rebuild): existing
  app-support plugins/DBs are abandoned; re-populate via the existing flows
  (Add Plugin…, mapper DB import, S&D installer, `dinv build`).

## The model
```
PluginLibraryEntry {
  id:    String          // MUSHclient plugin id (from the XML) — the identity/dedup key
  name:  String          // from the XML
  origin: .file(URL) | .url(URL)   // for the manual Update action only
  // dir is derived: ~/Documents/Proteles/Plugins/<slug(name)>/
}
```
- One global registry of added plugins (replaces both `LocalPluginStore` and the
  directory-scan "Installed" model). Per-character **enable** state stays in the
  world profile, keyed by MUSHclient id.
- One loader (`SessionController.loadPlugins()`) walks the registry, resolves
  each enabled entry's dir → `.xml` + module search path (its own dir) → loads
  via the existing compat shim. Replaces `loadPlugins(fromDirectory:)` +
  `loadLocalPlugins`.
- **`PluginDownloader`** — generalise `SearchAndDestroyInstaller` (URLSession
  download + `ditto` extract) for an arbitrary URL (a repo/branch zip via
  codeload, or a raw single `.xml`). S&D keeps using it.

## UI
One **Plugins** window list (no "Installed" / "Personal" split, no
"personal/local/private" wording). One **Add Plugin…** →
- **From your Mac** — pick a `.xml`, a folder, or multiple files; copied into a
  new `Plugins/<name>/` dir.
- **From a URL** — paste a URL; downloaded + extracted into `Plugins/<name>/`.

Both run the honest compatibility report, then register + enable for the current
world. Per-row: enable/disable (per world), **Reveal in Finder**, **Update**
(manual: re-copy from file / re-download from URL), **Remove** (delete the dir,
with confirm). Built-ins (mapper, dinv, S&D, native ports) stay a separate,
clearly app-provided group.

## Phases
- **Phase A — the library + discoverable plugin code (this deliverable).**
  `ProtelesPaths` home; `PluginLibrary` registry + per-plugin dir + `plugin.json`
  manifest; unified loader; `PluginDownloader`; the new Plugins-window UX; drop
  the personal/local/private terminology. **Data paths unchanged** (user plugins
  still use the existing per-profile world-data dir + sandbox root), so there's
  no broken intermediate and no sandbox-root churn.
- **Phase B — relocate data into the tree.** Per-plugin `data/<profile>/` +
  per-plugin lsqlite3 sandbox roots; mapper + S&D DBs → global `Databases/`;
  dinv data → `Plugins/dinv/data/<profile>/`. Touches the mapper-DB path (the
  open "loses its DB" bug area) — path change only; keep the NO-GUESSING stance.
- **Phase C (later)** — `Scripts/` + `Aliases/` under the tree; export/share a
  plugin (zip its dir).

## Security / trust
Unchanged from the prior plan: plugins run in the per-plugin `setfenv` sandbox +
lsqlite3 path guard; URL install is explicit + manual (confirm the source,
re-download on demand); the user is installing their own/community plugins
knowingly (MUSHclient parity); the sandbox is the guardrail. `~/Documents` is a
normal user-writable location (the app is not sandboxed). Privacy hard rule still
applies to the repo/commits/docs — the *capability* is generic; specific plugins
are never named.
