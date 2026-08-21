# CLua — provenance

The vendored Lua interpreter Proteles embeds: **Lua 5.1.5** (`LUA_RELEASE` in
`include/lua.h`), the same version MUSHclient ships, which is why community
plugins run unmodified. MIT-licensed — see `LICENSE.txt`.

Lua 5.1.5 is a frozen upstream (final release, 2012), so this is not a moving
dependency. It is vendored as source rather than linked, because the app needs
one interpreter it controls across every runtime (`ScriptEngine`, the
Search-and-Destroy host, the Lua console) and because the App Store forbids
loading a dynamic library at runtime.

## Local patches

The sources are otherwise **verbatim upstream**. Every deviation is listed here
and marked in the source with a `PROTELES PATCH` comment, so `grep -rn "PROTELES
PATCH" Sources/CLua` is an exhaustive audit.

### 1. `loslib.c` — `os_execute` under `LUA_NO_SYSTEM` (2026-08-21, iOS port I0a)

iOS marks `system()` `__unavailable`, so the stock `os_execute` body does not
compile for that platform. Guarded with `#if defined(LUA_NO_SYSTEM)`, which
`Package.swift` defines for iOS only. macOS compiles the unmodified upstream
body, byte-for-byte behaviour unchanged.

The patched branch keeps the function present and makes it *inert*, rather than
deleting it: removing `os.execute` would change the shape of the standard
library, and an unsandboxed runtime is contractually supposed to expose the full
library (`LuaRuntimeTests.unsandboxedKeepsLibrary`). It reports failure the way a
real `system()` would on a host with no shell — `os.execute()` → `0` ("no shell
available"), `os.execute("cmd")` → `-1` ("could not run").

This branch is unreachable in practice. The D-10 sandbox replaces the entire `os`
table with `{time, clock, date, difftime}` before any script runs, and the
MUSHclient compat shim overrides `os.execute` again on top of that (routing the
one idiom plugins actually use — `mkdir "<dir>"` — to the sandboxed
`makeDirectory`). Only an explicitly unsandboxed runtime can reach the C
function at all.

## Build settings

Set in `Package.swift` on the `CLua` target, per platform:

| Platform | Defines | Why |
|---|---|---|
| macOS | `LUA_USE_MACOSX` | Full macOS/POSIX feature set |
| iOS | `LUA_USE_POSIX`, `LUA_NO_SYSTEM` | See below |

iOS deliberately does **not** define `LUA_USE_MACOSX`. That macro also selects
Lua's legacy dyld loader (`LUA_DL_DYLD` → `NSLinkModule`,
`NSCreateObjectFileImageFromFile`, `_dyld_present`, …), every symbol of which is
unavailable on iOS — eight hard compile errors in `loadlib.c`. Plain
`LUA_USE_POSIX` leaves `LUA_DL_*` undefined, so `loadlib.c` compiles its
"dynamic libraries not enabled" stub. That is the desired posture independent of
the compile error: runtime native-code loading is barred by the iOS sandbox and
by App Store guideline 2.5.2, and D-10 already denies it inside Lua.

## If you ever re-vendor Lua

Lua 5.1.5 is final, so this should not happen — but if the sources are ever
replaced, the patch above will be silently lost, because it lives in an upstream
file. Re-apply it before building for iOS; the iOS CI job (`iOS Tests`) fails
loudly if you forget, since `loslib.c` will not compile.
