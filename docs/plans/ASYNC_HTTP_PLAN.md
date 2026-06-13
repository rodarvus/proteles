# Plan — `async` HTTP for plugins

> **Status: shipped (feature-complete for 1.0). Historical design doc — kept for the rationale and trade-offs.**

**Status: SHIPPED** (docs/DECISIONS.md D-67, post-`0.3.0` on `main`). Implemented over URLSession
as designed below; full parity (`doAsyncRemoteRequest`/`HEAD`/`GETFILE`),
outbound HTTP allowed freely (MUSHclient parity). Code:
`Sources/MudCore/Networking/HTTPClient.swift`, `LuaRuntime+HTTP.swift`,
`SessionController+HTTP.swift`, the clean-room `async` module in
`LuaRuntime+CompatShim.swift`; tests in `AsyncHTTPTests`.

## What it is

`async` is the Aardwolf MUSHclient package's HTTP helper
(`submodules/aardwolfclientpackage/MUSHclient/lua/async.lua`, ~182 lines). Plugins use it
to call web APIs / download files on a background thread. Real surface:

- `doAsyncRemoteRequest(url, callback, protocol, timeout, on_timeout, body)`
  — the one the corpus uses (lightRankStats posts stats to lightclan.net).
  `body` nil → GET, string → POST.
- `HEAD(url, callback, protocol, timeout, on_timeout)`.
- `GETFILE(url, callback, protocol, filename, timeout, on_timeout)`.
- Result callback signature:
  `callback(retval, page, status, headers, full_status, url, body)`.
- Timeout callback: `on_timeout(url, timeout, body)`.

Upstream is built on `llthreads2` + `socket.http` + `ssl.https` + `ltn12`,
polling completion via `DoAfterSpecial(0.2, "async.__checkCompletionFor(...)",
sendto.script)`.

## Why Proteles can do this cleanly

- **`URLSession`** does HTTP **and HTTPS** natively. No LuaSocket/LuaSec/threads
  needed.
- The "do work, then re-enter Lua to run a stored callback with results" model
  is exactly what our `DoAfter` / timer path already does. We don't even need
  the 0.2s poll — URLSession's completion handler drives the callback directly.

## Prior state (the 0.3.0 stub — since replaced)

Before this shipped, `require "async"` resolved to an **inert stub** (`asyncStubSource` in
`LuaRuntime+CompatShim.swift`): every `async.*` is a no-op, so a plugin that
uses it **loads and its local logic runs**, but network calls quietly do
nothing. The compatibility report shows a soft (verdict-neutral) note: "Talks
to the internet (the `async` helper), which Proteles doesn't support yet —
those parts won't work." For a plugin where the network *is* the feature (e.g.
lightRankStats' stat sync), that feature is effectively dead until this lands.

## Implementation (as shipped — was the proposal below)

1. **`ScriptEffect.httpRequest(url, method, headers, body, timeoutSeconds,
   callback: <persistent fn ref>, onTimeout: <persistent fn ref?>)`.** Needs a
   *persistent* Lua function-ref (current refs free at chunk end; a pending
   request must outlive that until completion — new infra in `LuaRuntime`).
2. **`SessionController`** runs it through an injectable **`HTTPClient`** seam
   (default `URLSession`; an `InMemoryHTTPClient` for hermetic tests, mirroring
   the `MudConnection` seam). On completion it re-enters the runtime to invoke
   the callback with the exact `(retval, page, status, headers, full_status,
   url, body)` shape; on timeout, the timeout callback.
3. **Clean-room `async` Lua module** exposing the real signatures
   (`doAsyncRemoteRequest`/`HEAD`/`GETFILE`) on top of that primitive — so
   lightRankStats and the update-checkers run unmodified. Replaces the stub.
4. **Tests:** unit via the HTTP seam (success, POST body, status codes,
   timeout, headers); a live check against a real endpoint.

## Decisions already made

- **Scope:** full parity (`doAsyncRemoteRequest` + `HEAD` + `GETFILE`), so
  update-checkers and file-download plugins also work — not just the GET/POST
  the corpus uses today.
- **Network gating:** **allow freely (MUSHclient parity).** Plugins may make
  HTTP(S) requests with no per-request prompt, as they do on Windows; the user
  runs only trusted plugins. (A future allowlist/toggle can layer on if needed,
  but is explicitly *not* required for the first cut.)

## Note: not the same as `aard_requirements`

`aard_requirements.lua` / `checkplugin.lua` are the package's *dependency-nag*
framework (check whether a companion MUSHclient plugin is installed; nag over
PPI if not). They are **not** networking and have **no meaning** in Proteles
(no MUSHclient plugin registry/PPI). The correct "implementation" there is the
no-op stub already shipped — do **not** try to make them faithful, or they'll
nag about plugins that are native Proteles features.
