# MUSHclient helper libraries — provenance

`wait.lua` and `check.lua` are **Nick Gammon's** standard MUSHclient utility
libraries (see the header in `wait.lua` → <http://www.gammon.com.au/forum/?id=4957>).
They ship in MUSHclient's own `lua/` folder and are posted by the author for
reuse in scripts; they are **not** part of Fiendish's GPLv3
`aardwolfclientpackage` plugin set.

Proteles bundles them (unmodified) so the MUSHclient compatibility shim and
plugins that `require "wait"` / `require "check"` (e.g. dinv, Search-and-Destroy)
resolve those modules. They carry no copyleft.

- `wait.lua`  — coroutine-based `wait.make` / `wait.time` / `wait.regexp` / … helpers.
- `check.lua` — return-code checker for MUSHclient API calls.
