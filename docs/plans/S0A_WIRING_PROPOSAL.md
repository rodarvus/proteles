# S0a wiring — proposal for review

> **Status: proposal. No code written.** Supersedes the wiring attempt that was
> reverted on 2026-08-25 after it caused a measured performance regression and
> was justified by a claim the recordings disprove. Tracking: **#82**.
>
> This document exists because the previous attempt went straight from "shall I
> build the wiring?" to a set of architectural decisions that were never put in
> front of anyone. Nothing here gets implemented without approval.

## 1. What went wrong, measured

### The regression is real, and localised to kill bursts

Paint latency from the recordings, bucketed by whether a `render:` sample falls
within 30 lines of an experience-gain line:

| Session | Build | Near-kill paint p50 | p90 | Ordinary output p50 |
|---|---|---|---|---|
| Aug 21 | pre-wiring | **437 ms** | 705 ms | 16 ms |
| Aug 24 | wired | **751 ms** | 1019 ms | 17 ms |
| Aug 25 | wired | **764 ms** | 1249 ms | 17 ms |

**Kill bursts got ~75 % slower; ordinary output is unchanged.** That matches the
reported symptom exactly — "very noticeable right after I kill a mob, when each
line output is slower compared to normal game output" — and explains why the
aggregate numbers looked ambiguous: the cost only shows where several displayed
lines arrive at once. A kill burst is 7–9 displayed lines in a single packet.

Note the pre-existing baseline: **437 ms was already slow.** Kill bursts were a
weak spot before this change; the wiring made a bad case worse. That is worth its
own issue regardless of what happens here (§5).

### Two mechanisms, both avoidable

1. **Classification ran before every guard.** `Soundpack.onLine` opened with
   `guard !config.muted` — a muted soundpack did **zero** regex work. The wiring
   ran `SemanticClassifier.events()` (48 compiled regexes) in the session, then
   checked mute afterwards inside the plugin. It also ran before checking whether
   *any* plugin cared, so the cost was paid even with the soundpack disabled.
   The recordings show **zero cues played**, so this was pure waste on every
   displayed line.
2. **An extra actor hop per displayed line.** `finishDisplayedLine` already
   awaits `scriptEngine.fireOnPluginScreendraw`; the wiring added a second
   `await` into the same actor, which is simultaneously processing inbound lines.
   In a burst those round-trips serialise behind contended work.

### The justification was wrong

The wiring was sold as fixing sounds firing for gagged lines. Across four
sessions and **593,246 gagged lines, zero** would have fired a sound event. The
asymmetry is real in the code and has never affected play.

**Consequence for this proposal:** moving sound to the displayed line is a
*correctness alignment with no observable benefit today*. It should be judged on
that basis, not as a fix. It is still worth doing eventually — a future trigger
`sound` action (S1) and the lens surfaces will care — but it does not justify
spending performance now.

## 2. Options

### Option A — Do nothing more in S0a; leave the layer unconsumed

Keep the committed pure types (`SemanticEvent`, `SemanticEventVocabulary`,
`SemanticClassifier`) and wire nothing until a consumer genuinely needs them.

- **For:** zero risk, zero cost. Honest about the fact that the only current
  consumer (sound) gains nothing observable.
- **Against:** #82's exit criterion says consumers use the layer with no
  behaviour regression. Leaves dead-but-tested code in the tree.

### Option B — Wire it, but only where work is already being done (recommended)

Classify **inside the existing `ScriptEngine.process(line)` call**, not at a new
seam, and carry the result forward to the displayed seam rather than re-entering
the actor.

- Classification happens once, in the actor pass that already runs.
- **No new actor hop.** No second `await` per displayed line.
- Guard order restored: check "is anything listening" and the soundpack's mute
  **before** running regexes.

**Correction (2026-08-25).** An earlier draft of this option claimed "the gag
decision is already known by the end of that pass". That is wrong, and worth
recording rather than quietly fixing. Only the *script/native* gag is known
inside `process`; Search-and-Destroy, rich-exits, wish-probe, blank and tag gags
are all decided afterwards in `appendLineWithGenericScripts`, and `shouldDisplay`
is the AND of all of them.

The corrected shape, which still needs no extra hop:

1. `ScriptEngine.process` classifies and fans events to native plugins **inside
   the existing pass**, collecting their effects.
2. Those effects ride back on the existing return value, kept **separate** from
   ordinary script effects.
3. `SessionController` applies them **only when `shouldDisplay` is true**, and
   discards them otherwise.

So a gagged line does its (guarded, usually zero) classification work but never
publishes — behaviourally identical to classifying at the displayed seam, at the
cost of one extra field on the disposition instead of one extra actor round-trip
per line.
- **For:** achieves the single-classification-point goal at roughly zero cost.
- **Against:** classification technically still happens in the raw pass, so the
  "classify the displayed line" wording of D-118 is satisfied in effect
  (events from gagged lines are discarded) rather than literally.

### Option C — Keep the displayed-line seam, make it cheap

Keep the wiring's shape but add a cheap pre-filter so the 48 regexes only run
when something could match, and hoist the "any consumer enabled?" check.

- **For:** literal fidelity to D-118's wording.
- **Against:** still an extra actor hop per displayed line — the mechanism I
  believe dominates the burst case. A pre-filter reduces regex cost but not
  contention, and the burst is a contention problem.

## 3. Recommendation

**Option B**, with the measurement plan in §4 agreed before any code.

Reasoning: it reaches the same end state — one classification point, one
vocabulary, consumers reading events instead of matching text — without paying
for a benefit that the recordings show does not exist yet. If the literal
displayed-line placement later earns its keep (a trigger `sound` action, a lens
subscribing), moving it is a small change *at that point*, justified by a real
consumer.

## 4. Measurement plan — agreed before implementing

Non-negotiable, since a test suite cannot catch this class of bug:

- **Metric:** `render: … arrival→paint`, p50/p90, bucketed **near-kill** (within
  30 lines of an experience-gain line) versus elsewhere.
- **Baseline:** Aug 21 recording — near-kill p50 437 ms, elsewhere 16 ms.
- **Pass condition:** near-kill p50 within noise of 437 ms; ordinary output
  unchanged. Any near-kill p50 above ~500 ms is a fail and gets reverted, not
  explained.
- **Method:** the user plays a session on the candidate build; the numbers come
  from the recording, not from a benchmark.
- **Also checked:** cue behaviour unchanged (channels, tells, quests, repop,
  level-up), because Option B must be behaviour-neutral.

## 5. Out of scope here, but worth an issue

**Kill bursts were already slow before any of this** — 437 ms p50 to paint,
against 16 ms for ordinary output, a ~27× difference. That is a pre-existing
weakness in how a multi-line burst moves through the pipeline, and it is
independent of the semantic layer. Recommend opening an issue rather than
folding it into #82.

## 6. What I need from you

1. **Option A, B, or C** — or a different shape.
2. **Confirmation of the pass condition** in §4.
3. Whether to open the kill-burst issue (§5) now or later.
