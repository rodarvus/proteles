# Per-plugin attribution — proposal for review

> **Status: approved 2026-09-03 (all three questions in §7, as proposed);
> implemented the same day, gates green, awaiting the A/B in §4.** Tracking:
> **#86** (the drift) and **#85** (the instrumentation gap it named). Precedes
> S0a item 5 by decision (2026-09-03). Implementation notes in §8.

## 1. The question the corpus cannot answer today

Every plugin trigger, alias and timer script runs through one call —
`runOwnedScript` in `ScriptEngine+Automation.swift` — timed as
`session.script.lua.plugin`. The note it emits is:

```
perf: session.script.lua.plugin 281ms events 1 login+7784.6s live
```

It says *a* plugin took 281 ms. It does not say which. #86 established, by
measurement, that these invocations are ~30 % slower than two weeks ago on an
unchanged binary, and today's per-character tabulation narrowed it further:

| | Character A | Character B |
|---|---|---|
| Plugins loaded | 20 | 12 (all also loaded for A, identical trigger counts) |
| Kills in the example session | 1331 | 1018 |
| `lua.plugin` samples ≥ 50 ms | 5730 | 238 |
| Their p50 | 160 ms | 63 ms |

So the slow work is either one of the eight plugins loaded only for A, or the
per-character state of a shared plugin (A's plugin databases are ~50× B's).
Those two readings need different fixes, and only a plugin name on each sample
separates them. No further analysis is worth doing without it.

## 2. What changes

### 2.1 The probe learns an optional attribution

`PerformanceProbe.recordPhase` and `measure` gain `attribution: String? = nil`.
When present, the `perf:` note gains a trailing field:

```
perf: session.script.lua.plugin 281ms events 1 login+7784.6s live plugin=leveldb
```

When absent, the note is **byte-identical to today**, so the two-week corpus
and every existing test keep their meaning.

The pressure summary (`groups[phase]`, the "top phases by count/time" lines)
keeps grouping by the aggregate phase name. It is a health summary, not an
attribution tool, and fragmenting it across twenty plugins would make it
worse at its own job.

### 2.2 The burst breakdown gains a second line

`BurstTracker.accumulate` gains the same optional attribution. Attributed
samples accumulate under a `(phase, attribution)` key — a `Hashable` struct,
no string building per sample — and are reported on **their own line** after
the burst note, ranked by cost, only when non-empty:

```
burst: 9 lines 468ms | lines.script-engine 420ms · script.trigger-match 60ms · …
burst-plugins: script.lua.plugin[leveldb] 380ms · script.lua.plugin[dinv] 40ms
```

The existing `burst:` line and its 12-phase cap are untouched. A second line
keeps the corpus parsers valid and stops per-plugin keys from pushing
sub-phases out of the cap.

### 2.3 The engine passes the name where it already knows the owner

`ScriptEngine` keeps `loadedPluginIDs` but not names; `loadPlugin` has
`plugin.name` in hand. One stored dictionary, `pluginNames: [String: String]`,
filled in `loadPlugin` and cleared where `loadedPluginIDs` is. (A stored
property, so it lives in `ScriptEngine.swift`, not an extension.)

Three call sites attribute, all with `owner` already resolved:

| Phase | Site | Covers |
|---|---|---|
| `session.script.lua.plugin` | `runOwnedScript` | the script body — trigger, alias **and** timer scripts, since all three route here |
| `session.script.trigger-script.plugin` | the firing loop in `ScriptEngine+Process.swift` | the whole firing (sync + script + registration) |
| `session.script.consume-registrations` | `runOwnedScript` | what a script registered afterwards — cheap to include, and `AddTriggerEx` churn is a plausible drift mechanism |

The lookup is one dictionary read on the engine actor. **No new actor hop**,
no runtime call.

### 2.4 Not attributed in this cut: plugin callbacks

`fireCallbackOnAll` (`OnPluginBroadcast` per GMCP packet,
`OnPluginScreendraw` per displayed line, `OnPluginTelnetSubnegotiation`) has
no per-plugin timer today, only the outer `session.gmcp.script-apply`. Adding
one is a **new** measurement in a hot loop, and the data says the time is not
there: the Sep 2 12:27 session has 5730 `lua.plugin` samples and 17
`gmcp.script-apply` samples. Left out on purpose; the seam is one line if the
attributed corpus later points at callbacks.

## 3. What does not change

- Phase names, thresholds, the 50 ms floor, the 100 ms burst gap.
- The `burst:` line format and cap; the pressure summary; `perf-burst:`.
- Anything outside `PerformanceProbe.Mode.full` — every path is already behind
  `recordsAttribution`, and the new parameter defaults to `nil`.
- Plugin behaviour, the shim, the runtime. Nothing a script can observe.
- Transcript privacy posture: the transcript already prints plugin names in the
  load census (`[plugins] <name>: N triggers …`), so a name on a `perf:` line
  exposes nothing new. Transcripts stay local.

## 4. Cost, and the measurement plan

Outside `.full`: unchanged (a `nil` default and the existing guards).

Under `.full`, per attributed sample: one dictionary read for the name, one
extra dictionary add in the burst tracker, one optional-string copy into the
snapshot. Formatting happens only at note time (≥ 50 ms) and burst close, as
today. Against 125–160 ms scripts this is noise, but per CLAUDE.md the claim
is measured, not asserted:

- **A/B on the same day**, Release, control = the commit before this one
  (identified by the `build:` line), both with `.full` on.
- **Metrics:** `lua.plugin` p50 and sample count per kill (per-event
  normalisation), and near-kill `arrival→paint` per position after a kill.
- **Pass:** within noise of the control on both; the count of `perf:` notes
  per kill unchanged (attribution adds a field, never a note).

## 5. Tests

1. `recordPhase` with attribution renders `plugin=<name>`; without it, the
   exact current string (pinned literally, so a regression in the base format
   fails loudly).
2. `BurstTracker`: attributed samples produce a `burst-plugins:` line ranked
   by cost; unattributed bursts produce no such line; the `burst:` line is
   unchanged either way.
3. Engine end-to-end: under `.full`, a trigger owned by a loaded plugin emits
   a `lua.plugin` note carrying that plugin's name; a user (unowned) script
   emits `lua.user` with no attribution; a timer script and an alias script
   carry the name too.
4. Cost: outside `.full` nothing is recorded (extends the existing test).

## 6. After approval

Implement → four macOS gates + the iOS gate (MudCore is touched) → Release
build installed → the user plays with `.full` on **both** characters. The
first kill session then names the plugin, and #86 resumes on that data.

## 7. What I need from you

1. Approve the shape (§2), in particular the second `burst-plugins:` line
   rather than folding names into the capped `burst:` breakdown.
2. Confirm callbacks stay out of this cut (§2.4).
3. Confirm the pass condition in §4.

*Answered 2026-09-03: second line; callbacks out; pass condition as proposed.*

## 8. Implementation notes (2026-09-03)

Built as specified in §2, with one addition the proposal did not list:

- **`ScriptEngine.probe`**, a stored property defaulting to
  `PerformanceProbe.shared`, with an internal `useProbe(_:)` setter. Every
  engine timing call now goes through it instead of naming the singleton.
  Production behaviour is identical. It exists because the end-to-end test
  (§5.3) shares the process-wide probe with every session test running in
  parallel, any of which may `flushBurst()` and drain a burst mid-test — which
  is exactly what the first full-suite run did. A private probe per test
  engine makes the test deterministic. Test plumbing, not design.

Two corrections to this document's examples, found by the tests: the short
phase name in a burst line is `script.lua.plugin`, not `script.plugin` (the
`session.` prefix is what gets trimmed), so the second line reads
`burst-plugins: script.lua.plugin[leveldb] 380ms · …`; and the whole-firing
phase appears alongside it as `script.trigger-script.plugin[leveldb]`.

Gates: `swift build`, `swift test --parallel` (2,087 tests), `swiftformat
--lint` (modulo the local 0.63/CI 0.61 `wrapIfStatementBodies` noise),
`swiftlint --strict`, and the iOS simulator gate — all green on the final
tree. The §4 A/B is the user's to run: two Release builds, control at the
previous commit and candidate at this tree, same day, same character.
