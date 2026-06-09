# MUSHclient helper libraries — provenance

`wait.lua`, `check.lua`, and `string_split.lua` are **Nick Gammon's** standard
MUSHclient utility libraries (see the header in `wait.lua` →
<http://www.gammon.com.au/forum/?id=4957>). They ship in **MUSHclient's own
`lua/` folder** (upstream MUSHclient, not Fiendish's GPLv3
`aardwolfclientpackage` plugin set) and are posted by the author for reuse in
scripts.

Proteles bundles them (unmodified) so the MUSHclient compatibility shim and
plugins that `require "wait"` / `require "check"` / `require "string_split"`
(e.g. dinv, Search-and-Destroy, Hadar) resolve those modules. They carry no
copyleft.

- `wait.lua`  — coroutine-based `wait.make` / `wait.time` / `wait.regexp` / … helpers.
- `check.lua` — return-code checker for MUSHclient API calls.
- `string_split.lua` — defines the global `string.split(self, pat, …)` (pattern-based
  split, like `utils.split`); the world importer doesn't copy MUSHclient's shared
  `lua/` dir, so plugins requiring it need it provided here.
