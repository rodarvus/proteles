# S0b item 1 — the state model's frame

> **Status: implemented 2026-10-30 and confirmed live** (approved 2026-10-28
> as proposed: Q1 (a), the inspector is its own window opened from Settings ▸
> Development; arrival counts added per §11). Tracking: **#84**.
> Order of work: `S0B_SCOPE_PROPOSAL.md` §3 (D-129), item 1 of 8.

## 1. The ratified scope, verbatim

From **#84**'s checklist (D-129):

> - [ ] 1. The state model's frame: a pure MudCore value updated at S0a's
>   seams (no new actor hop per line), how consumers read it, what "feed
>   absent" looks like, corpus replay extended to state, and the macOS
>   **State inspector** shell (a read-only debugging surface, not a lens)

From **D-129**:

> S0b listens and switches no feed on (D-123; #87 owns enabling), and the
> model says when a feed is absent rather than showing empty state as truth.
> The Mapper, `GMCPState`, `ChatStore` and S&D keep owning their data; the
> model references them rather than copying.

### 1.1 My reading

- **The frame holds no entity yet.** Occupants, items, spells and the rest
  arrive with items 2–7, each adding its own slot, parser and inspector
  row. Item 1 builds what they all share:
  - where the state lives and the two seams that feed it;
  - the tag-block collector;
  - per-feed "seen / not seen" status;
  - how a native plugin and the UI hear about a change;
  - the corpus replay of state;
  - the inspector window.
- **"Feed absent" is per feed, not per entity.** Each entity later reads its
  feed's status: no `{roomchars}` block this connection means occupants are
  *unknown*, while an empty block means the room *is* empty. Item 1 builds
  the status table that makes that distinction.

## 2. What exists

**The seams S0a uses.** Every inbound line, displayed or gagged, enters
`ScriptEngine.process(_:)` first (`SessionController+LineProcessing`), raw
and before any gag decision. Every GMCP packet reaches
`ScriptEngine.applyGMCP` (`SessionController.dispatchGMCPToScripts`). Native
plugins are called from both, inside the engine actor, so anything the
engine holds is reachable from them with no extra hop.

**The engine lives for the app's lifetime.** It is created once in
`ProtelesApp`. `connectNativePlugins()` runs on each connect, which makes it
the natural reset point.

**How UI state leaves the engine today.** A plugin returns an effect that
carries a snapshot (`.updateConsider(ConsiderSnapshot)`). The session
yields it on a stream (`applyStoreEffect`), and the app bridges that into an
`@Observable` model that only the reading views observe. `GMCPStateModel`
records why: a root-level value reassigned per packet stalled the window.

**The tag blocks, as recorded.** Each block is an opening marker, optionally
with arguments, then raw lines, then a closing marker:

```
{roomchars}
(R) The seething crossbill flies through the sky, …
(F)(G) The starflier gracefully weaves through the celestial currents.
{/roomchars}
```

- `{spellheaders hsp}` … `{/spellheaders}`, about 1,200 lines;
- `{invdata}` and `{invdata <container>}` … `{/invdata}`;
- `{roomobjs}` … `{/roomobjs}`, `{eqdata}` … `{/eqdata}`.

`{exits}` and `{invmon}` are single tagged lines.

**Corpus check (October, 114 sessions).** Every block that opened also
closed, with nothing unclosed and no stray closings:

| Block | Opened = closed | Longest (lines) |
|---|---|---|
| `roomchars` | 138,495 | 18 |
| `roomobjs` | 138,422 | 46 |
| `spellheaders` | 1,445 | 619 |
| `invdata` | 673 | 531 |
| `eqdata` | 11 | 29 |

So the collector's edge rules (§3.1) guard against something the corpus
has never shown. The cap is set at **2,000 lines**, about three times the
longest block.

**What the corpus replay does today** (`Tests/MudCoreTests/Replay/`): it
replays every `.jsonl` through the real line pipeline into the two
classifier entry points. It holds the result two ways:

- **invariants**: an independent recogniser must agree with the layer;
- **pin and diff**: a per-session baseline under `~/Documents/Proteles`,
  re-pinned deliberately.

The replay is opt-in (`PROTELES_REPLAY=1`).

## 3. What changes

### 3.1 MudCore: the model and the tracker

New files under `Sources/MudCore/Semantic/State/`:

**`ActionableState`.** A pure `Sendable, Equatable` value: what consumers
read. In item 1 it carries only the feed table:

- `feeds: [Feed: FeedStatus]`;
- `Feed` is the closed list of S0b's feeds:
  - tag blocks: `roomchars`, `roomobjs`, `invdata`, `eqdata`, `spellheaders`;
  - tag lines: `exits`, `invmon`;
  - GMCP: `room.info`, `char.vitals`, `char.status`;
- `FeedStatus` is `.unseen` (nothing this connection), or `.seen(since:)`
  plus, for blocks, a completed-block count and the last incomplete block,
  if any.

**`TagBlockCollector`.** A pure value that turns lines into completed
blocks: `(feed, arguments, lines)`. It owns the edge rules:

- a block ends at its own closing marker;
- an opening marker of a *collected* family while another block is open
  drops the open one and marks it incomplete;
- a line cap (2,000, §2) marks a runaway block incomplete.

Lines inside a block pass on to triggers, plugins and display exactly as
today. The collector only observes.

**`ActionableStateTracker`.** A pure value: the collector plus the state.

- `ingest(_ line:)` and `ingest(gmcp:)` each return which entities changed.
  In item 1 that is always none, because there are no entities yet; the
  feed table still updates.
- The cost on a non-tag line is one first-byte check plus one "is a block
  open" check: no regex, no allocation.

### 3.2 The seams (no new hop)

- `ScriptEngine` holds one tracker as a stored property. It must live in
  `ScriptEngine.swift`, which goes from 591 to about 594 lines. The logic
  goes in a new `ScriptEngine+State.swift`.
- **Lines:** `process(_:)` ingests the line **first**, before triggers and
  native plugins, so a plugin reacting to a line sees state that includes
  it. Two details:
  - The ingest runs **before** the `suspended` early return and the
    `wantsSemanticEvents` guard. State records what the game sent, whatever
    scripts are doing, and costs one byte check.
  - It is independent of display, like D-128's structural events: tag
    lines are hidden by the norm.
- **GMCP:** `applyGMCP` ingests before `nativePlugins.onGMCP`.
- **Reset:** `connectNativePlugins()` resets the tracker, so every feed
  reads `.unseen` on a fresh connect.

### 3.3 How consumers read it

- **Native plugins:** a new protocol requirement with a default no-op:

  ```swift
  mutating func onStateChange(_ state: ActionableState,
                              changed: Set<ActionableState.Entity>) -> [ScriptEffect]
  ```

  The registry calls it on enabled plugins only when an *entity* changed,
  not on a feed-status bump. Its effects ride the line's or packet's own
  effects, so they apply on the displayed and gagged paths alike. Item 1
  defines the hook. `ConsiderFeature` is its first implementer, in item 2,
  replacing its private `handleRoomchars`.
- **The UI:** when anything in the state changes, including feed status,
  the engine appends `.updateState(ActionableState)`. The session yields it
  on a new `actionableStates` stream, `SessionController`'s one new stored
  property (589 → about 592 lines). The app bridges it into an
  `@Observable` `ActionableStateModel` in MudUI, read only inside the
  inspector's own body, per `GMCPStateModel`'s lesson.
- **Publication rate.** A snapshot is published only on a real change:
  - a feed first seen;
  - a block completed (a `{roomchars}` block about every 6 s, or a room
    move);
  - later, an entity change.

  A repeated `{invmon}` line or a vitals packet changes nothing once the
  feed is seen, so it publishes nothing. That is why tag-line and GMCP
  feeds keep `since` and no per-line count.

### 3.4 The State inspector (macOS)

- A **window** (`Window("State", id:)`), opened by a button in Settings ▸
  Development, with no menu-bar item (DESIGN.md §3.5). See Q1.
- In item 1 it shows one table, the feeds:
  - the name and its kind (tag block, tag line, GMCP);
  - "not seen this connection", or "since HH:MM:SS";
  - for blocks, the count and any incomplete block.

  Each later item adds its entity's section.
- The view (`StateInspectorView`) and the model are in **MudUI**, so the
  iOS port can reuse them for the same debugging. The window scene is in the
  app target.
- It is read-only: no actions, no feed toggles (#87 owns enabling).

### 3.5 The corpus replay of state

`CorpusReplay` gains a state pass. The tracker ingests every decoded line
and GMCP message of each session, in order.

- **Invariant:** an independent count of opening/closing marker pairs per
  family, found by plain string matching, must equal the tracker's
  completed blocks. Every incomplete block is listed with its line index,
  so a real one in the corpus is visible rather than silently dropped.
- **Pin:** per session, which feeds were seen and the block count per
  family, in a separate pin file (as `CorpusReplay+Cues.swift` does for
  cues). Later items add their entities' pins to it.

## 4. Options considered

**Where the state lives**

- **A. A value held by `ScriptEngine`, beside the native-plugin registry.
  Proposed.** Both seams already run there, and the promoted consumers
  (`ConsiderFeature`, Inventory Serials) are native plugins there, so
  reading it costs nothing.
- **B. Its own actor**, like `GMCPStateStore`. Rejected: one more actor hop
  per line, which is the trap CLAUDE.md names, and the native plugins would
  need a second hop to read it.
- **C. A native plugin of its own.** Rejected: plugins can't read one
  another, and state can't be something a user disables.
- **D. Held by `SessionController`.** It sees every line, but the plugins
  that consume state are in the engine: a hop per change. Rejected.

**How plugins read it**

- **An `onStateChange` callback. Proposed.** It fires on a change, which is
  exactly what `ConsiderFeature`'s "re-consider when the occupant set
  changes" needs.
- **State passed into `onLine` and `onGMCP`.** Rejected: it changes every
  plugin's signature, and plugins would diff state themselves.

**Copying GMCP into the model.** Rejected by D-129: room, vitals and status
stay in `GMCPState` and the Mapper. Item 3 decides how the model names them.
Item 1 only records that their feeds were seen.

## 5. Open question

**Q1 — Where does the inspector open?**

- **(a) Its own window, opened from Settings ▸ Development. Recommended.**
  You can keep it beside the main window while you play, which is what
  live verification needs, and the menu bar stays calm.
- **(b) A section inside Settings ▸ Development.** No new window, but it
  sits in the Settings window, which is awkward to watch while playing.
- **(c) A Window-menu item.** Easiest to reach, but it puts a debugging
  tool in daily-play menus.

## 6. What does not change

- **No feed is enabled**, and no `tags` command is sent (D-123, #87).
- **Display, gags and triggers:** the collector only observes. A line
  inside a block reaches triggers, plugins and the output exactly as
  today.
- **S0a's events and their seams** (`semanticEffects`, D-128's split): the
  ingest sits beside them and doesn't touch them.
- **`ConsiderFeature` and Inventory Serials** are unchanged until items 2
  and 4.
- **`GMCPStateStore`, the Mapper, `ChatStore` and S&D.**

## 7. Impact and measurement

- **Hot path.** It adds, per line, a first-byte check and an "is a block
  open" check, ahead of the guards (the CLAUDE.md trap is named here on
  purpose). Lines inside a block are appended to a buffer, a few per room
  look. Per GMCP packet, it adds one switch on the package name.
- **Measurement plan (before code):**
  1. **Offline:** a `PerformanceBench` case (`B6`) replays the largest
     recording through the tracker, reporting ns per line overall and per
     tag line. Run on the control commit and on the change, same
     configuration.
  2. **Live:** a `session.script.state` probe phase. One Release session
     on the change against a same-day Release control build (this commit's
     parent), compared per kill on `perf-burst` and `render: arrival→paint`
     near kills.

  **Expected: noise-level.** If either run shows more than noise, I stop
  and report before handing over.
- **Risk.** `onStateChange` and `.updateState` are new contract surface.
  The rest is additive and observes only.
- **Files:**
  - MudCore: `Semantic/State/{ActionableState, TagBlockCollector,
    ActionableStateTracker}.swift`, `ScriptEngine.swift` (one property),
    `ScriptEngine+State.swift`, `ScriptEngine+Process.swift`,
    `ScriptEngine.applyGMCP`, `NativePlugin.swift` (the hook and the
    registry's fan-out), `ScriptTypes.swift` (`.updateState`),
    `SessionController.swift` (one property), `SessionController+StoreEffects.swift`.
  - MudUI: `State/{ActionableStateModel, StateInspectorView}.swift`.
  - App: the window scene, and a button in `DevelopmentSettingsView`.
  - Tests, below.

## 8. Tests

- **`TagBlockCollector`:** a block with arguments; an empty block; an
  interrupted block (marked incomplete); the cap; lines outside any block
  untouched; a non-collected marker inside a block (kept as a line).
- **`ActionableStateTracker`:** `.unseen` until a feed arrives; `since`
  set once; the block count; reset; no change reported for a repeated
  tag line.
- **Engine:** a line inside a block still reaches triggers and display
  unchanged; the tracker sees a block while scripts are suspended;
  `.updateState` is emitted on a first-seen feed and not on a repeat;
  `onStateChange` isn't called on a feed-status bump.
- **Replay** (opt-in): the invariant and the pin, as in §3.5.

**Live check for you:** open Settings ▸ Development ▸ State Inspector and
play for a minute. `{roomchars}`, `{exits}` and the GMCP feeds should
read "since …", and the `{roomchars}` count should rise as you move. Type
`i` and `{invdata}` should appear. `{roomobjs}` should read "not seen"
unless it is on in your game settings.

## 9. After this item

Item 2 (occupants) adds the first entity, its parser over completed
`{roomchars}` blocks, `ConsiderKeyword`'s promotion, and `ConsiderFeature`
as the first `onStateChange` consumer.

## 10. Implementation notes and measurement (2026-10-29)

**B6 came in over the "noise-level" expectation**, so it was reported
before handover (§7) and the user chose to gate the probe (option A
below) and accept the rest.

| B6, ns per line (Release, interleaved runs) | Control (7ddd4921) | Change |
|---|---|---|
| First build | 951–972 | 1,180–1,193 |
| + one parse per tag line, name filter | — | 1,083–1,086 |
| + probe gated on lines that can change state | 958–979 | 1,063–1,072 |

The largest recording (1,254,793 lines, 151,145 of them tag lines). The
final delta is about +98 ns per line (+10%). B6b puts the tracker alone
at about 64 ns per line: 16 ns per non-tag line and about 415 ns per tag
line, which includes collecting the lines inside blocks.

What moved it:

- **One parse per tag line.** The first build parsed each tag line with
  `AardwolfTags.marker(in:)`, which walks `Character`s and builds a payload
  string, and parsed every non-block tag line twice. `FeedMarker` now
  parses once for both the collector and the tag-line feeds. It reads the
  marker name from the UTF-8 bytes and sends only S0b's seven names on to
  `leadingTag`, which stays the grammar's single authority. Across the
  October bench session, 46% of tag lines (`{rdesc}`, `{coords}`,
  `{rname}`, …) are not S0b's. On 772,449 distinct tag lines from every
  transcript, `FeedMarker` agrees with the old path with zero mismatches.
- **The probe is gated.** `probe.measure` takes a lock just to read the
  probe's mode, which cost about 37 ns per line even with the probe off.
  `ingestState` now returns before the probe unless the line is a tag or a
  block is open (`ActionableStateTracker.mayChange(on:)`), so the live
  `session.script.state` phase measures only lines that do state work.
- **No copy-on-write on append.** The collector releases its own reference
  to the open block before appending, so a long block grows in place
  rather than being copied on each line.

The full corpus replay (457 sessions, 54.2M lines) holds every invariant,
the state invariant included. The event pin diff was limited to one
recording that was still being written during the run (additions only).
The cue and state pins also reported diffs, but their text wasn't
captured, so they aren't confirmed to come from that recording alone.

## 11. Arrival counts for tag-line and GMCP feeds (2026-10-30)

After the live check, the user asked for counts on the five rows that
showed only "Since …". This revises §3.3's "no per-line count" (approved:
a 5-second refresh; "lines" and "packets" as the wording).

- `FeedStatus.arrivals` counts every `{exits}` and `{invmon}` line and
  every `room.info`, `char.vitals` and `char.status` packet.
- **Publishing is throttled.** A count bump on its own is reported once
  `ActionableStateTracker.countRefresh` (5 s, by the input's own clock) has
  passed since the last reported change. Any other change reports at once
  and carries the counts. When the stream goes quiet, up to the last 5 s of
  arrivals can stay unshown until the next line or packet.
- Counts are not entities, so `onStateChange` is never called for them.
- The inspector reads "Since 7:06:07 · 1,234 lines" for tag lines and
  "· 5,678 packets" for GMCP.
- **Replay invariant:** independent counts of tag lines (by prefix) and of
  GMCP packages (by name) must equal each feed's arrivals. The pin is
  unchanged.
- **Cost:** B6b is unchanged (65.6 ns per line). Same-day B6 with and
  without the counts is the same (1,075–1,112 ns), against a control at
  956–971 ns. The B6 delta reads about +120 ns today against +98
  yesterday; with or without the counts it is the same, so that drift
  isn't the counts.
