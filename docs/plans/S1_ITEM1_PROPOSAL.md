# S1 step 1 — GMCP-sourced events enter the layer

> **Status: proposed 2026-10-23, awaiting approval.** Tracking: **#83**.
> Design answers this builds on: **D-127**.

## 1. The ratified scope, verbatim

From **D-118**:

> **S1** (event→cue map as data; per-category volumes under a master; ducking
> hooks; trigger `sound` action emitting events; notification sounds unified;
> playback discipline; preview + onboarding)

From **D-120**:

> **S1 stands in full** … only the speech-coupled parts defer (ducking hooks,
> unmute onboarding).

From **D-127** (1):

> **Event routing is generic; sound is one consumer.** Where events enter the
> layer and how they fan out knows nothing about sound

### 1.1 Why this is step 1

\#83's first task is the cue map as data. It can't be built cleanly yet:
the soundpack still classifies three GMCP packages itself (`Soundpack.onGMCP`:
`comm.channel`, `comm.quest`, `comm.repop`), while
`SemanticClassifier.events(forGMCP:json:speakerMuted:)` exists, is covered by
the corpus replay, and has **no production caller**. Line events reach
consumers through the layer and GMCP events don't. So the soundpack has two
input paths, and `onSemanticEvent` filters to `.pattern` sources only
(`43bd3dcd`) to avoid double cues. This step closes that gap before anything
is built on top of it. Every later S1 item, and every lens, then reads **one**
input: `onSemanticEvent`.

## 2. What changes

- **`NativePluginSet.onGMCP`** (`NativePlugin.swift`): after the existing
  per-plugin `onGMCP` loop, and only when `wantsSemanticEvents` is true,
  classify the packet once with
  `SemanticClassifier.events(forGMCP:json:speakerMuted:)` and fan each event
  through the existing `onSemanticEvent`. `speakerMuted` comes from the
  `GMCPDispatchContext` the method already builds, so there's no second Chat
  Echo call.
- **`Soundpack.onGMCP`** loses the cue classification for those three
  packages. It keeps what isn't classification: tracking `selfName` from
  `char.base`, and the inline `!!SOUND` handling (with its Chat Echo mute
  check).
- **`Soundpack.onSemanticEvent`** drops the `.pattern`-only filter. It takes
  events from any source. Tag-sourced events (`affect_on`, `skill_gain` …)
  have no cue in the reference table, so they stay silent until the cue map
  gives them one.

Effect order for a `comm.channel` packet doesn't change: the inline `!!SOUND`
cue comes first, then the channel cue.

## 3. What does not change

- The classifier, its vocabulary, and the rule that a Chat Echo-muted speaker
  produces no event. This is the S0a contract, already under replay test.
- Line classification and its gag rule (events from a gagged line are never
  published).
- The `wantsSemanticEvents` opt-in gate. It is temporary (D-127), but
  removing it is a separate decision, made when a lens first consumes the
  layer.
- Every audible behaviour: same cues, same files, volumes, pan, and the same
  Chat Echo mute.
- Chat capture, notifications, the mapper, S&D, and the Lua `gmcp.*` paths.
  They read GMCP directly and are untouched.

## 4. Options considered

- **A. Classify in `NativePluginSet.onGMCP`** — proposed. The dispatch
  context (decoded `CommChannel`, Chat Echo verdict) is already computed
  there, and `NativePluginSet` is the fan-out every native consumer reads
  through, lenses included (D-124).
- **B. Classify in `ScriptEngine.applyGMCP`**, beside the line path's
  `semanticEffects(for:)`. This is more symmetric to read, but it needs the
  mute verdict from `NativePluginSet`, either by exposing the context
  (another `CommChannel` decode per packet) or by moving the context builder
  out. More churn, same result. Rejected.
- **C. Leave GMCP cues in the soundpack.** This keeps two input paths, and
  every S1 item (cue map, category volumes, discipline) would have to handle
  both. Rejected: it's the duplication S0a exists to remove.

## 5. Tests

- **Generic routing (fails without the change):** a stub native plugin that
  wants semantic events receives a `.gmcp(package: "comm.quest")` event when
  `NativePluginSet.onGMCP` gets a `comm.quest` packet. Today it receives
  nothing. The test has no sound in it.
- **No double cue:** an unmuted soundpack produces exactly one channel cue
  per `comm.channel` packet, and no cue for a Chat Echo-muted speaker.
- **Same cues across the corpus (pin-and-diff, as in S0a item 7):** on the
  current commit, replay the local corpus's GMCP through `NativePluginSet`
  with an unmuted soundpack (config URL `nil`) and pin the `.playSound`
  counts per file. After the change, the counts must be identical. Local
  only, nothing uploaded.

## 6. Hot path: measurement plan

This runs per GMCP packet, but only while something wants events (today, an
unmuted soundpack):

- **Added work:** one `lowercased()` and a switch that falls through for
  every package except three.
- **Moved work, not added:** the `comm.channel` decode and the `comm.quest`
  parse move from the soundpack into the classifier.

The plan:

- **Two builds:** a same-day control (the previous commit) and the change,
  both Release, soundpack unmuted.
- **One ordinary play session on each build.**
- **What to compare:** the `session.gmcp.script-apply` phase from the
  existing `perf:` probes, per packet, median and p99, bucketed near-kill vs
  elsewhere.
- **Pass:** no difference outside the run-to-run noise.

If you'd rather skip the A/B for a change this small, say so. The rule asks
for an agreed plan, and "none" is an answer you can give.

## 7. Impact and risk

- **Behaviour:** none intended, and none audible if the pin-and-diff holds.
- **Regression class:** double or missing channel/quest/repop cues. The
  no-double-cue test and the corpus pin cover it.
- **Files:** `NativePlugin.swift` (watch the 600-line limit; split into
  `NativePluginSet+Semantic.swift` if needed), `Soundpack.swift`, and new
  tests. No app-target changes.
