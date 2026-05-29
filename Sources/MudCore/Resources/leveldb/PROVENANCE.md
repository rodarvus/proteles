# leveldb — provenance

`leveldb.xml` is vendored **verbatim** (unmodified) from the upstream
`rodarvus/leveldb` plugin (also tracked as the repo submodule at `/leveldb`),
commit `a137c60`. MIT-licensed (see `LICENSE`).

leveldb is a passive "leveling database": it watches the MUD output + GMCP and
records kills / deaths / quests / campaigns / global-quests / power-ups / level
events into a SQLite database, queried with its `ldb …` command surface. It has
**no miniwindows** and `require`s only `gmcphelper` — so it runs through the
generic MUSHclient compatibility shim, exactly like the vendored `dinv` (D-32).

**Policy:** run it **unmodified**, with behaviour identical to MUSHclient. Any
gaps it surfaces are closed in *our shim*, never by editing this file. (V1 goal;
a native reporting view over its SQLite is a separate later feature.)
