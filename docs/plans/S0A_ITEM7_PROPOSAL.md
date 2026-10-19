# S0a item 7 — transcript-driven replay tests

> **Status: approved 2026-10-19 (§6 answered yes, yes, yes); implemented the
> same day; first pin run (§7) reviewed and accepted; committed. S0a complete.**
> Tracking: **#82**. Shape agreed 2026-09-16 after
> review: **local corpus replay, nothing uploaded**, with **invariants plus
> pin-and-diff** ("B with (iii)"). Implementation notes in §8.

## 1. The ratified scope, verbatim

D-121: "…events on the internal bus, **transcript-driven replay tests**."

#82: "**Transcript-driven replay tests against real recordings**", and the
exit criterion: "**The layer classifies real recorded sessions correctly under
test**, and sound/notifications consume it with zero behaviour regressions in
daily play."

`AARDWOLF_DATA_FEEDS.md` §8: "Fixtures come from recordings, not from
hand-written samples. … Configurable surfaces get more than one fixture. …
Tag-dependent features test the disabled path. … Feeds marked 'unknown' in §7
must not be guessed."

### 1.1 The reading, as confirmed

Items 1–5 are tested one corpus line at a time. Item 7 is the whole-session
net: recorded sessions go through the real pipeline, the classifier and the
router produce their event stream, and that stream is held against the last
reviewed one. Any change to a regex, a tag parser, or the guard shows up as a
diff against real play.

Three points settled in review (2026-09-16):

1. **Input is the `.jsonl` wire recording**, replayed through the real telnet,
   ANSI and MCCP2 pipeline. It carries every byte the server sent: lines,
   GMCP subnegotiations, the compressed stream. It lacks outbound commands and
   the client's gag decisions, which live only in the human `.log`. Neither is
   needed: the harness tests **raw-line classification**, the layer's own
   contract; the gag-then-apply rule is covered by the engine tests.
2. **Nothing leaves the machine.** The harness reads the corpus in place and
   writes its baseline beside the app's own state, outside the repo. No
   fixture is checked in, so no scrubbing.
3. **"Correctly" is defined two ways.** Invariants that need no review, and a
   baseline you review once and re-pin when a change is intended.

## 2. What exists

| Piece | Role |
|---|---|
| `SessionReplayer` | Parses a `.jsonl`, replays chunks through `LinePipeline`, collects lines and negotiation responses — **but drops the pipeline's GMCP output** |
| `LinePipeline.Output.gmcp` | The decoded `GMCPMessage`s per chunk, already produced |
| `PerformanceBenchTests` | The pattern to copy: `.enabled(if:)` on an env var, `realHome()` (not `ProtelesPaths`, which redirects to a temp dir under test), corpus listing from `~/Documents/Proteles/Recordings` |
| `SemanticClassifier.events(forDisplayed:)` / `events(forGMCP:json:)` | The two classification entry points |
| The corpus | 194 `.jsonl` recordings, 244 MB, largest 10.7 MB |

## 3. The design

### 3.1 The replayer keeps GMCP

`ReplayOutput` gains `gmcp: [GMCPMessage]`, appended per chunk. Three lines.
Without it `comm.quest`, `comm.repop` and channel events cannot replay.

### 3.2 The harness — a test-side value type, no new MudCore surface

`Tests/MudCoreTests/Replay/CorpusReplay.swift`:

```
struct CorpusReplay {
    struct Session { name; lines: Int; gmcp: Int; events: [Event] }
    struct Event: Codable, Hashable { index: Int; name: String; source: String; payload: [String: String] }
    static func replay(_ url: URL) throws -> Session      // pipeline → classifier → events
    static func summary(_ s: Session) -> [String: Int]    // "affect_on/tag": 412, …
    static func diff(_ a: Session, _ b: Session) -> Diff   // added / removed events by (index, name)
}
```

`replay` runs every line through `events(forDisplayed:)` (prose rules and the
tag router, exactly the production path) and every GMCP message through
`events(forGMCP:json:)`. `index` is the line's position in the replay, so a
diff points at a line you can open in the `.log`.

### 3.3 The invariants — self-validating, no baseline

One suite, over every session in the corpus:

| Invariant | What it guards |
|---|---|
| Every well-formed `{affon}`/`{affoff}`/`{recon}`/`{recoff}`/`{sfail}`/`{skillgain}` line yields exactly one tag event, of the documented name | the router never drops or doubles |
| No line that does not start with `{` yields a tag-sourced event; no GMCP event comes from a line | source tiering is a property, not a convention |
| Every event name is in the vocabulary and carries its vocabulary category | no stray names, no fallback categories in the wild |
| Every prose event's line matches its own rule when run alone | the classifier's rule set is consistent with itself |
| Counts per event name equal counts of their source lines | a summary you can trust without reading it |
| Per §8, the disabled path: sessions with no `{affon}` lines at all yield no affect events, reported per session | the tag-dependent path degrades to nothing, not to noise |

### 3.4 Pin and diff — the review you do once

Baseline: `~/Documents/Proteles/Diagnostics/replay-baseline/<session>.json`,
one file per recording, outside the repo. Behaviour:

- **No baseline for a session:** write it, report "pinned", pass.
- **Baseline present:** diff; **fail** on any difference, printing per session
  the counts that moved and the first twenty changed lines with their text
  (local file, never uploaded), so the review is the failure message.
- **`PROTELES_REPLAY_PIN=1`:** overwrite baselines, pass. The deliberate
  re-pin after a change you have reviewed.

The first run pins everything; that first summary is what I hand you to
review, session by session, before anything counts as "correct".

### 3.5 Gating

`.enabled(if:)` on `PROTELES_REPLAY`, like the bench, **not** on the corpus
merely existing. Reason: a 244 MB replay inside every local `swift test`
would turn a 50 s gate into a multi-minute one and get skipped by habit. The
run is deliberate:

```sh
PROTELES_REPLAY=1 swift test --filter CorpusReplay
```

CI never sets the variable and never has the corpus, so it skips. New
recordings are picked up automatically on the next run and pinned.

### 3.6 Cost

Offline only; nothing on the play path. Runtime estimate from the bench's
measured classifier cost: the corpus decodes to roughly ten million lines,
so a Debug run is on the order of ten minutes. The first run's real number
goes in §7. Per-session progress is printed so a long run is visibly alive.

## 4. What does not change

- The classifier, the router, the engine, the guard. The harness only calls
  the same two entry points production calls.
- The repo's fixtures: none added. The default `swift test` and CI: unchanged.
- Nothing is uploaded; the baseline lives under `~/Documents/Proteles`.
- Gag interplay stays with the engine tests (§1.1).

## 5. Tests for the harness itself

- `ReplayOutput.gmcp` is populated: a synthetic chunk with an option-201
  subnegotiation yields one `GMCPMessage` through `replay(into:)`.
- `summary`, `diff` and the baseline round-trip on synthetic sessions: added,
  removed, unchanged, and a re-pin.
- The invariants run against the checked-in welcome-banner fixture, which
  must yield zero events — the smallest disabled-path case.

## 6. What I need from you

1. **Gate on `PROTELES_REPLAY`** rather than corpus presence (§3.5)?
2. **Baseline location** `~/Documents/Proteles/Diagnostics/replay-baseline/`?
3. **The failure message shows line text** for changed lines. It is local
   output only; confirm that is acceptable.
4. After approval: I implement, run the first pin, and hand you the summary
   to review before item 7 is called done.

## 7. First run (2026-10-19)

`PROTELES_REPLAY=1 swift test --filter CorpusReplay`, Debug, on the whole
local corpus:

| | |
|---|---|
| Sessions | 410 (all pinned; 305 carry spellup tags, 105 do not) |
| Lines decoded | 49,348,057 |
| GMCP messages | 4,374,598 |
| Invariant violations | **0** |
| Wall clock | 4,007 s (66.8 min); the largest session is 935k lines |
| Baseline on disk | 410 files, 53 MB, under `~/Documents/Proteles/Diagnostics/replay-baseline/` |

Events by tier (the full list is in the run log; the baselines hold every
event with its line index):

| Tier | Events | The large ones |
|---|---|---|
| tag | 341,899 | `affect_on` 152,475 · `affect_off` 152,271 · `cast_failed` 18,382 · `skill_gain` 16,828 · `recovery_on`/`off` 972/971 |
| gmcp | 67,837 | `clantalk` 24,924 · `zone_repop` 6,631 · `auction` 6,329 · `claninfo` 5,110 · `gossip` 3,893 · quest lifecycle ~5,000 |
| pattern | 54,706 | `cp_mob_dead` 22,424 · `sh_powerup` 12,089 · `info` 7,980 · `level_up` 5,996 · `quest_target_found` 1,912 · `bonus_item` 1,243 |
| **all** | **464,442** | |

Three things worth the reviewer's eye, none a defect:

- **On/off pairs balance.** `affect_on` 152,475 vs `affect_off` 152,271;
  `recovery_on` 972 vs `recovery_off` 971. The gaps are affects still
  running at session end.
- **Two events exist at two tiers.** `quest_warning` fires 88 times from
  `comm.quest` and 14 from the prose rule (`QUEST: You have run out of
  time…`); `gtell` 498 from GMCP and 21 from the group-invite prose rules the
  reference maps to that name. Both are the GMCP > pattern ordering rule
  showing: the layer emits both, and a consumer prefers the durable tier by
  `Source.durability`. S1 decides whether to dedupe at the cue.
- **The disabled path held.** All 105 sessions without spellup tags yielded
  zero affect events.

The 66 minutes is Debug and single-threaded by design (one pass, one
session in memory at a time). It is a deliberate, occasional run, not a
gate; if it ever needs to be routine, a Release test build and per-session
parallelism are the two obvious levers, neither needed now.

## 8. Implementation notes (2026-10-19)

Built as specified in §3, with four notes:

- **One pass, two suites.** The invariants and the pin-and-diff are separate
  suites for separate failure messages, but a 658 MB replay must not run
  twice per `swift test`. `CorpusReplayRun.shared` runs the corpus once,
  lock-guarded, and both suites read its result. Each session's lines are
  released before the next is read, so memory stays at one session.
- **Independent recognisers, on purpose.** The invariants restate the six
  event tags, their field counts, and the `comm.quest` action table in the
  test file rather than calling the router or the classifier for the
  expectation. A recogniser that shares code with the thing it checks can
  only agree with it. A self-test feeds the invariants a deliberately wrong
  session (dropped tag event, stray tag event, mislabelled category, missing
  repop) and requires all five violations.
- **Event position.** A GMCP event takes the index of the first line emitted
  after it. The pipeline does not preserve interleaving inside a chunk, so
  this is "near here", good enough to find the moment in the `.log`.
- **The corpus grew** from 194 recordings / 244 MB at proposal time to 410 /
  658 MB at first run. §2's figures stand as written; §7 has the real ones.

Gates: build, 2,152 tests across the three targets, swiftformat, swiftlint,
and the iOS simulator gate (run after the corpus pass, not alongside it).
