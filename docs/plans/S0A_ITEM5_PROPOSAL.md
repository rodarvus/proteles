# S0a item 5 — `AardwolfTags` as the tag-family router

> **Status: approved and implemented 2026-09-07; gates green; awaiting the
> §5 A/B before commit.** Implementation notes in §7. Tracking: **#82**.

## 1. The ratified scope, verbatim

From **D-118**:

> build **S0** (SemanticEvent taxonomy in MudCore; classifier demoted to the
> built-in Aardwolf vocabulary pack on the *displayed*-line path;
> `NotificationMatcher` generalized as the user rule engine; **`AardwolfTags`
> promoted to a tag-family router**)

From **D-121**:

> `AardwolfTags` as the tag-family router (**built here; S0b extends it to the
> entity-feed families**)

and, on what S0a's events are:

> S0a's ephemeral, log-like *events* (combat round, kill, level, **affect
> on/off**, repop)

From `IOS_PORT_PLAN.md` §4a:

> `AardwolfTags` promoted from stripper to **tag-family router**, starting
> with `CHANNELS`/`TELLS`/`SAYS`

### 1.1 My reading, for you to confirm or correct

Today `AardwolfTags` is a display transform: it recognises a leading `{tag}`
marker and either strips it or hides the line. Item 5 makes it a **router**: a
tagged line is identified by family, and the families whose payload is an
*event* are parsed into `SemanticEvent`s with source `.tag(family:)` — the
structural tier between GMCP and prose. S0b later adds the entity-feed
families (occupants, items, exits) to the same router. The display transform
keeps its behaviour.

**The "hide tags" behaviour stays, unchanged.** `displayLine(for:)`, the
`machineDataTags` list, the marker stripping, and the "clean tag markers"
preference are not touched by this item: routing decides what the *layer*
learns from a tagged line; display decides what the *player* sees, exactly
as today. The two are independent — a hidden `{affoff}58` still yields its
event, and a routed line is still hidden. *(Confirmed 2026-09-07.)*

### 1.2 The rule, and the one correction to the wording

**The router uses tag families exclusively for data GMCP does not carry.**
That is the whole rule, and it decides every family question in this item
and in S0b without a per-family debate:

- **Comms are GMCP.** `comm.channel` carries every channel kind in two weeks
  of recordings, 20 in all including say, tell and group tell, and echoes the
  player's own sends. The reference package never enables the comm tag
  families; both of its chat plugins read `comm.channel` only. So
  **`CHANNELS`, `TELLS` and `SAYS` are not enabled, not routed, not parsed —
  not now, not later.** This proposal never suggested otherwise; the earlier
  draft of this section discussed the amendment at a length that could read
  as ambivalence, and it is rewritten here so it cannot.
- **The six events in §3.2 pass the rule.** No GMCP package in the corpus
  (14 packages: `char.*`, `room.*`, `group`, `config`, `comm.channel`,
  `comm.quest`, `comm.repop`, `comm.tick`, `room.wrongdir`) carries affects,
  recoveries, cast failures or skill gains. Aardwolf publishes those only as
  `SPELLUPS` / `SKILLGAINS` tags and the `slist` command.

§4a's "starting with `CHANNELS`/`TELLS`/`SAYS`" was written before the feed
map existed and contradicts the rule. It is corrected in the same commit as
the code, recorded as **D-123**, with the sentence above as its text.
*(Ratified 2026-09-07.)*

## 2. What exists today

| Piece | Role |
|---|---|
| `AardwolfTags.leadingTag(in:)` | The marker grammar: `{`, optional `/`, lowercase identifier, optional ` args`, `}` |
| `AardwolfTags.machineDataTags` | Nine families whose lines hide entirely (`coords`, `invmon`, `affon`, `sfail`, …) |
| `AardwolfTags.displayLine(for:)` | Strip the marker or hide the line — **display only**, behind the "clean tag markers" preference |
| `SessionController.measuredTagCleanLine` | The seam that calls it, after every gag decision |
| `ConsiderFeature` | Buffers `{roomchars}…{/roomchars}` itself (S0b will promote this) |
| `InventorySerialsPlugin` | Reads `{invdata}` itself (S0b) |
| `refreshRichExits` / `setRichExitsEnabled` | The **feed-ownership precedent**: a feature sends `tags exits on` once per session and `tags exits off` when disabled |

The corpus, whole (`RECV` lines starting with a marker):

| Family | Lines | Kind |
|---|---|---|
| `coords` / `rname` / `roomchars` / `roomobjs` / `rdesc` / `exits` | 116k–263k each | entity (S0b) |
| `invmon` / `invitem` / `invdata` / `eqdata` | 169k / 30k / 2.5k / 190 | entity (S0b) |
| **`affon` / `affoff`** | **51,903 / 51,766** | **event** |
| **`sfail`** | **8,570** | **event** |
| **`skillgain`** | **8,820** | **event** |
| **`recon` / `recoff`** | **200 / 200** | **event** |
| `scan`, `spellheaders`, `begin running`/`end running`, `help*`, `bigmap`, `mapper_wait` | — | block/command output (S0b or never) |

(`{begin running}` / `{end running}` are not a family at all: they are
Proteles' own walk markers, echoed by the mapper and gagged as `walkmarker`.)

### 2.1 Sanity check against dinv, the heaviest tag consumer we ship

Read on 2026-09-07 at your request (`plugins/dinv/dinv_items.lua`,
`dinv_dbot.lua`). Three findings, one warning heeded.

1. **Which families, and how they are parsed.** dinv reads `{invmon}`
   (per-line, one regex, `^{invmon}(.*?),(.*?),(.*?),(.*?)$`), `{invitem}`
   (per-line, eight fields), and the block families `{invdata}` / `{eqdata}`
   / `{keyring}`: a start trigger on `^{(eqdata|invdata|keyring)[ ]?([0-9]+)?}$`
   enables a per-line stats trigger and registers a one-shot end trigger on
   `^{/(eqdata|invdata|keyring)}$`, which disables them again. That is a
   **line-at-a-time state machine** — exactly the shape `ConsiderFeature`
   already uses for `{roomchars}`, and the shape S0b's block router will use.
   Nothing in the tag parsing itself is asynchronous.
2. **Where the asynchrony is, and why it is not ours to copy.** dinv wraps
   every *command it sends* in a "safe execution" layer: a coroutine queue
   (`wait.make`), an echoed fence line (`echo { DINV fence N }`) to detect
   that the command's output has ended, and `dbot.callback.wait` spinning on
   `wait.time(0.1)` against 2 s / 5 s timeouts, with recovery paths for
   AFK, note mode and quit. That machinery exists because dinv *initiates*
   commands (`invdata`, `eqdata`, `identify`) and must know when their
   output is complete. **The router initiates nothing.** It classifies lines
   the game already sends; there is no command, no completion to await, no
   timeout, no coroutine. Your warning stands as a design constraint for
   S0b too: block families are a start/end state machine over inbound lines,
   never a request/response layer.
3. **dinv does not enable tags either.** Its only `tags` reference is its own
   CLI (`dinv tags refresh organize set on`, unrelated to Aardwolf's `tags`
   command). It relies on `INVMON` being on for live updates, and on the
   `invdata` / `eqdata` / `keyring data` commands, whose output is tagged
   regardless of any family — `{invdata}` appears 2,456 times in the corpus
   with the `INV` family off. Same posture as Option A in §3.4.

The vocabulary today has **no affect events at all**: every affect a player
sees is prose (`You feel yourself moving at the speed of light!`), which the
classifier does not match either. The structured lifecycle sits unused in
`SPELLUPS`, which is **on** for this player and emits per `help spelltags`:

| Tag | Payload | Meaning |
|---|---|---|
| `{affon}72,1650` | spell#, seconds | spell landed, duration |
| `{affoff}72` | spell# | spell wore off |
| `{recon}15,1200` | recovery#, seconds | cooldown started |
| `{recoff}15` | recovery# | cooldown expired |
| `{sfail}72,0,2,-1` | spell#, target (0 self / 1 other), reason, recovery# | cast failed; reasons 1–12 enumerated in the help |
| `{skillgain}223,99` | skill#, new % | skill improved (`SKILLGAINS`, on) |

## 3. The design

### 3.1 Router, not a fourth matcher

`AardwolfTags` gains the routing half beside the display half:

```
enum AardwolfTags {
    enum Family: String, CaseIterable   // the closed list from `tags`, all 27
    static func family(of line: String) -> (family: Family, closing: Bool, args: String)?
    static func events(forTagged line: String) -> [SemanticEvent]   // event families only
}
```

- `Family` names **every** family the `tags` command lists, so S0b adds
  parsers, not a mechanism. Recognition is the existing `leadingTag` grammar.
- `events(forTagged:)` parses the six event tags above into events. Anything
  else returns `[]` in S0a.
- Pure value code in MudCore, no state: each of the six tags is one line, one
  event. Block families (`{roomchars}…{/roomchars}`) need buffering and are
  S0b's problem by D-121.

### 3.2 The events

Six names, in the categories the taxonomy already has (`.affect` exists in
`SemanticEvent.Category`; the vocabulary simply has no members yet):

| Tag | Event | Category | Payload |
|---|---|---|---|
| `{affon}` | `affect_on` | `.affect` | `spell` (number), `seconds` |
| `{affoff}` | `affect_off` | `.affect` | `spell` |
| `{recon}` | `recovery_on` | `.affect` | `recovery`, `seconds` |
| `{recoff}` | `recovery_off` | `.affect` | `recovery` |
| `{sfail}` | `cast_failed` | `.affect` | `spell`, `target` (`self`/`other`), `reason` (code), `reasonName` (from the help's table), `recovery` when ≥ 0 |
| `{skillgain}` | `skill_gain` | `.progression` | `skill`, `percent` |

Source is `.tag(family: "spellups")` / `.tag(family: "skillgains")`, durability
1. Numbers stay numbers-as-strings in the payload, consistent with the rest of
the layer; resolving a spell number to a name needs `slist`, which is S0b's
spell entity, so it is not done here.

`cast_failed` is the one worth a sentence: it is the only structured signal
for *why* a cast failed (immune, already up, no mana, cooldown), which the
lens design (§4a there) marks "available, unused", and it is exactly what a
combat lens will need to say "pick another".

### 3.3 Where it runs — the Option B seam, same guard

Inside `ScriptEngine.process`, next to the existing `semanticEffects(for:)`,
behind the same `nativePlugins.wantsSemanticEvents` guard, with a first-byte
check (`{`) ahead of the parse. Events ride back on `LineDisposition.
semanticEffects` and are applied only if the line survives every gag, exactly
as the prose events do. No new actor hop, no new seam.

Routing is independent of the "clean tag markers" preference: a hidden
`{affoff}58` line still yields its event. The display transform is untouched.

### 3.4 Feed ownership — a decision for you

The §3 policy in `AARDWOLF_DATA_FEEDS.md`: *a feature must own its feed rather
than assume it.* `SPELLUPS` and `SKILLGAINS` are on for **this player**; they
are off by default for everyone else. Two options:

- **A. Route only; enable nothing in S0a (recommended).** The router turns
  what arrives into events. The `tags spellups on` command is sent by the
  first *consumer* that needs affect events, through a one-line
  `AardwolfTags.enableCommand(for:)`, mirroring `refreshRichExits`. S1's
  affect cues or S0b's spell entity is where that consumer appears. No
  behaviour change for any player in this item.
- **B. The router enables both families on connect when any semantic
  consumer is listening.** Faithful to "own the feed" now, but it changes
  what other players see (their scroll and paging go off) for events nobody
  consumes yet.

A is the crisp one: it is the whole of the enablement, and it does not spend
another player's paging on nothing.

*Decided 2026-09-07: **A**. In the fullness of time a first-use setting or
dialog should recommend the families lenses need and offer to enable them
once, with the scroll/paging consequence stated — owned by the phase that
ships the first lens, tracked as **#87**.*

### 3.5 What I am explicitly not doing

- **Not** touching the entity families (`roomchars`, `roomobjs`, `invmon`,
  `invdata`, `invitem`, `eqdata`, `exits`, `coords`, `rname`, `rdesc`,
  `scan`, `spellheaders`). D-121 puts them in S0b, and their consumers keep
  their own parsing until then.
- **Not** enabling, routing, or parsing `CHANNELS`/`TELLS`/`SAYS` (§1.2).
- **Not** changing display: stripping, hiding, `machineDataTags`, the
  preference. A router that changed what the player sees would be two items.
- **Not** resolving spell numbers to names; **not** adding UI or settings.

## 4. Tests

- **Transcript-driven, per `AARDWOLF_DATA_FEEDS.md` §8:** the six grammars
  from the corpus samples above (`{affon}614,1200`, `{affoff}58`,
  `{recon}2,494`, `{recoff}2`, `{sfail}104,0,2,-1`, `{skillgain}223,99`),
  each pinned to its event and payload; `{recoff}0` and `{sfail}…,-1` edge
  values included because the corpus has them.
- **The reason table** from `help spelltags`, pinned code by code (1–6, 8–12;
  7 is absent in the help and must map to unknown, not invented).
- **Family totality:** `Family` covers the 27 names from the bare `tags`
  command, and every event family is a member.
- **Guard order:** with no listening plugin, a tag line does no parse
  (extends the existing guard test); a non-tag line pays a first-byte check.
- **Not a display change:** `displayLine(for:)` results unchanged for every
  fixture, hidden lines still hidden.
- **Vocabulary totality** updates for the six new names.

## 5. Measurement plan — same as Option B

Tag lines are ~1.6M of the corpus, so this is a hot path. Same-day A/B against
the previous commit, Release, full attribution, same character: Lua p50 and
paint by position after a kill within noise; the `lines.script-engine` burst
phase unchanged. Pass condition per the amended CLAUDE.md rule.

## 6. What I need from you

1. **Ratify §1.2** — the comm families leave item 5's wording, recorded as
   D-123 with the §4a correction.
   *Answered 2026-09-07: ratified, as the rule "tags exclusively for data GMCP
   does not carry".*
2. **Confirm §1.1** — the reading of "router" and the S0a/S0b split of
   families.
   *Answered: confirmed, with the explicit condition that "hide tags" stays
   (now stated in §1.1).*
3. **§3.2 names and categories**, or corrections.
   *Answered: sensible as proposed.*
4. **§3.4: A or B.**
   *Answered: A, with the first-use recommendation as a later follow-up
   (#87).*
5. Confirm §5.
   *Answered: agreed.*

Also requested and done: the dinv sanity check, §2.1.

## 7. Implementation notes (2026-09-07)

Built as specified in §2–§3, with three notes:

- **Placement.** §3.3 said "inside `ScriptEngine.process`, next to
  `semanticEffects(for:)`". The tag branch lives one call deeper, inside
  `SemanticClassifier.events(forDisplayedText:)`, so the classifier stays the
  *single* classification point D-118 asks for and the engine is untouched.
  Same guard (`wantsSemanticEvents` runs first), same disposition, same
  gag-then-apply rule; the first-byte check sits ahead of the parse. The
  prose rules still run on tag lines exactly as before, so nothing already
  classified changes.
- **Files.** The routing half is `AardwolfTags+Router.swift` (the `Family`
  list, the marker→family map, `marker(in:)`, the six-event parser); the
  display half is untouched in `AardwolfTags.swift`. Both use the one marker
  grammar, `leadingTag(in:)`, so routing and display cannot disagree about
  what is a tag.
- **Corrections to this document, found while implementing.** The bare
  `tags` command lists **27** families, not 26 (`MAPEXITS` and `MAPNAMES` are
  separate rows; the feeds-doc table joined them). `where` is a Swift keyword
  and is backticked in the enum. The vocabulary's "no strays" test now
  checks names against both built-in sources, the soundpack pack and the
  router, rather than the soundpack alone.

Tests: 19 in `AardwolfTagRouterTests.swift` (corpus fixtures with provenance,
the reason table with code 7 pinned to `unknown`, family totality against
the `tags` output, the marker map, comm families recognised-but-never-routed,
malformed payloads, out-of-scope markers, display unchanged, classifier and
engine end-to-end with and without a listener) plus one new vocabulary test.
Gates green: build, 2,109 macOS tests, swiftformat, swiftlint, iOS simulator.
The §5 A/B is the user's: control = `~/Applications/Proteles-control.app`
(this tree before item 5, shim fix included), candidate =
`~/Applications/Proteles.app` (same plus item 5); both stamp `c1383209 dirty`,
so the sessions are told apart by which app was launched.
