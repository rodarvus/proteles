# leveldb — provenance

`leveldb.xml` is vendored **verbatim** (unmodified) from the upstream
`rodarvus/leveldb` plugin, tracked as the repo submodule at `plugins/leveldb`,
commit `9c67ce0` (v9.4 — writes the DB to `proteles.databaseDir()` on Proteles;
v9.3 added WAL + `synchronous=NORMAL` to fix combat write stalls). MIT-licensed
(see `LICENSE`).

**Re-vendoring is reproducible and CI-guarded (GitHub #67).**
`scripts/vendor-plugins.sh` copies this file verbatim from the submodule; there
is no patch (leveldb is unmodified). `scripts/vendor-plugins.sh --check` runs in
CI and fails if this copy drifts from the pinned submodule. To pick up a new
release: bump the submodule, re-run the script, update the version/commit above,
then rebuild + test.

leveldb is a passive "leveling database": it watches the MUD output + GMCP and
records kills / deaths / quests / campaigns / global-quests / power-ups / level
events into a SQLite database, queried with its `ldb …` command surface. It has
**no miniwindows** and `require`s only `gmcphelper` — so it runs through the
generic MUSHclient compatibility shim, exactly like the vendored `dinv` (D-32).

**Policy:** run it **unmodified**, with behaviour identical to MUSHclient. Any
gaps it surfaces are closed in *our shim*, never by editing this file. (V1 goal;
a native reporting view over its SQLite is a separate later feature.)
