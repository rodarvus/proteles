# S0a item 5 — `AardwolfTags` as the tag-family router

> **Status: design proposal. No code written.** Tracking: **#82**.

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

### 1.2 The one amendment to the wording — needs your ratification

§4a says the router starts with `CHANNELS`/`TELLS`/`SAYS`. Established on
2026-09-03 from the corpus and the references (see the conversation record):

- `comm.channel` carries every channel kind in two weeks of recordings, 20 in
  all including say, tell and group tell, and echoes the player's own sends.
- The reference package never enables the comm tag families; both of its chat
  plugins read `comm.channel` only.
- Those three families are **off** on the live config, and enabling any family
  disables the game's scroll and paging; `TELLS` also changes tell behaviour.
- What the tags would add is *line identity* for the display gag (Chat Echo
  pairs the inline copy by text today). That is a display concern, not a
  semantic-layer one, and it is not worth scroll and paging.

Your stated position: *"all comms (channels, tells, says) should come from
GMCP, rather than tags."* This proposal is written on that basis: **the router
does not start with, enable, or route the comm families.** If you ratify it,
I record it as **D-123** and correct §4a in the same commit as the code.

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
    enum Family: String, CaseIterable   // the closed list from `tags`, all 26
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
- **Family totality:** `Family` covers the 26 names from the bare `tags`
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
2. **Confirm §1.1** — the reading of "router" and the S0a/S0b split of
   families.
3. **§3.2 names and categories**, or corrections.
4. **§3.4: A or B.**
5. Confirm §5.
