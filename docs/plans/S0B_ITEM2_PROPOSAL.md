# S0b item 2 — occupants

> **Status: approved 2026-10-30: Q1–Q3 as recommended (a, a, a), and Q4
> (keyword overrides, added the same day at the user's request) as (a), a
> Proteles-owned store.** In-game facts settled (§7).
> Tracking: **#84**. Order of work: `S0B_SCOPE_PROPOSAL.md` §3 (D-129), item
> 2 of 8. Builds on item 1's frame (`S0B_ITEM1_PROPOSAL.md`).

## 1. The ratified scope, verbatim

From **#84**'s checklist (D-129):

> - [ ] 2. Occupants: `{roomchars}` + `ConsiderKeyword` promoted out of
>   `ConsiderFeature`, `(P)` players never targets; `ConsiderFeature`
>   becomes a consumer

From **D-129**:

> (1) **The exit's "real surface"** is each entity's promoted consumer
> (`ConsiderFeature` for occupants, Inventory Serials for items) … (2)
> **Adjacent-room occupants (`{scan}`) and failed moves (`room.wrongdir`) are
> out** …

And from **D-123**: S0b listens and switches no feed on; whoever consumes a
feed owns enabling it.

The occupant's handle (`LENS_DESIGN.md` §4) is a **targeting keyword**. The
question this document answers is where that keyword can honestly come
from, and at what cost.

## 2. Findings

### 2.1 `{roomchars}` is presence, not names

`{roomchars}` is the room's `look` list: one **room description** per
occupant, with aura flags in front.

```
(P)(F)(W) (OPK) Tinada the Chronicler [R/C].
(R) A needle-tailed soulcatcher snatches dreams from unsuspecting sleepers below.
```

Every recording where the Consider feature ran (3 sessions, 263
`consider all` runs) was compared against the `{roomchars}` block just
before each run:

| Measure | Result |
|---|---|
| Non-player `{roomchars}` count equals the considered count | 228 of 263 runs (87%) |
| Considered name found anywhere in a description | **297 of 677 names (44%)** |

"A krait" is *"a small, slate grey viper hides and waits"*; "A hanuman
langur" is *"a long-limbed, long-tailed, black-faced monkey nibbles some
fruit"*. A keyword can't be derived from `{roomchars}`. It does reliably
say **how many** mobs there are, which are players (`(P)` or the long form
`(Player)`, both seen), and their aura flags. It also says when that
changed. It costs nothing: S&D already enables it, and it arrives with
every `look`.

Also: `ConsiderFeature` doesn't parse these lines. It uses the whole block
as a "the room changed" signature.

### 2.2 Where short names do appear

| Source | Names? | Flags? | Tier? | Cost | How often it appears today |
|---|---|---|---|---|---|
| `consider all` | yes | yes | **yes** (13 tiers, plus divine protection and shopkeeper lines) | one command per room, on demand | only when Consider/S&D/the player sends it; 3 recordings ever |
| `{scan}`, its `Right here you see:` section | yes | yes | no | one command | already flowing whenever S&D or the player scans: 275 "Right here" sections in the last 40 sessions |
| Arrival / departure / flee / kill prose | yes, for that one mob | no | no | free | constant, but only describes changes |
| `{roomchars}` | **no** (descriptions) | yes | no | free | every `look`, every room |

`{scan}` is tagged and lists short names with flags, the same shape
`consider` gives (`- (F)(G) A sunrise mallard`). D-129 (2) set `{scan}`
aside as **adjacent-room** occupants. Its `Right here you see:` section is
the *current* room, which item 2 covers, so using it is a reading of D-129
for you to confirm (Q2).

### 2.3 What `consider all` costs

Measured from the 263 recorded runs (Release, Aug–Sep):

- **Round trip, send to sentinel:** median 0.9 s, p95 3.2 s. That's mostly
  queueing behind other output, not the command itself.
- **Commands:** two per refresh (`consider all` plus the sentinel `echo`),
  each queued with the player's own commands. During a speedwalk or a fight
  they go into the same queue.
- **Rate with auto-refresh on:** 25 an hour over a 10-hour session; 166 an
  hour in one short burst.
- **Wait state (measured).** The sentinel `echo` is sent in the same
  millisecond as `consider all`. It comes back **441 ms** after the last
  consider line (median; p95 598, max 684; 251 runs). For ordinary
  command-and-echo pairs (dinv's fences, 1,976 pairs) the same gap is
  **112 ms** (p95 151). So `consider` holds the player's *next* command
  back by about a third of a second: a short delay, not seconds. `help
  consider` doesn't mention it. Caveat: the consider runs are from August
  and the fences from October; the gap is measured between two of the
  server's own responses, so network latency largely cancels.
- **No `commandtags`.** `consider all tags` answers "Nobody here with that
  name." (2026-10-30 10:56), so the game parses `all tags` as a mob name.
  A sentinel or an outbound-command window is the only way to delimit
  consider output.
- **The grammar** (`help consider`): bare `consider` covers the whole room
  and `consider <monster>` covers one. The 13 messages and level ranges
  match our `ConsiderTiers` exactly. "Fighting them" is the help's
  wording; the live game also says him, her or it (Areia's pattern). Two
  more lines come from S&D's triggers, not the help: `<mob> has divine
  protection.` and `If you killed <mob>, who would serve … customers?`
  (shopkeepers). Both mean the mob can't be attacked; our port has
  neither.

### 2.4 Areia's plugin (`areia_consider.xml` v1.20, AreiaAard/Areia_Consider)

What players apparently rely on:

- **On demand by default.** `ac` considers. Auto mode (`ac auto`) is **off
  by default**, fires on room entry (`room.info`) and on area repop
  (`comm.repop`), and never while running or while the mapper is mid-run.
- **Auto mode switches itself off on a zone change.** The plugin's own
  comment says this is "to cut down on people spamming groups".
- **Brackets the output:** `echo {consider}`, `consider all`,
  `echo {/consider}`. Its 14 patterns are enabled only inside the bracket,
  so they cost nothing per line otherwise. It skips safe rooms and
  non-active states.
- **Keywords differ from ours.** Areia keeps *every* non-stop word (each
  truncated at a hyphen or apostrophe) and targets `N.'w1 w2 w3'`. S&D's
  `gmkw`, which we ported, keeps first and last word cut to 5 letters
  (`boat pirat`). Both have per-user overrides: Areia's `ac keywords`, and
  S&D's `mob_keyword_exceptions` table, which we read.
- It also matches "*X* has divine protection." (unattackable), a pattern
  our port doesn't have.
- **It never attacks automatically.** Its help warns that doing so breaks
  the botting rules. Ours doesn't either (`conwall` is user-triggered).

### 2.5 How Search-and-Destroy detects mobs

`xset nx <smartscan|con|scan|scanhere|qs|none>` sets what S&D does on
arriving in a room via `nx` or `go` (`action_on_destination_arrived`):

| Mode | Sends | Notes |
|---|---|---|
| **smartscan** (the default when its auto-con setting is on) | `scan`, then `con` only if needed | the "Right here" names are compared against the **`{roomchars}` line count**. Fewer scanned than present means "potential noscan mobs", so it falls back to a consider (`consider_end`, the 548 "Target not found on smart scan…" notes in your recordings) |
| con | `consider` | the whole room, with tiers |
| scan / scanhere | `scan` / `scan here` | **noscan mobs don't show** |
| qs | `scan <target keyword>` | its current target only |
| none | nothing | |

Points that matter here:

- **`scan` misses noscan mobs; `consider` doesn't.** `{roomchars}` is what
  tells S&D that something is missing. That is the same count check as
  Q1 (a) below, which S&D has used for years.
- S&D's fallback `con` is **unbracketed** (`SendNoEcho("con")`, ended by
  the next blank line). A listener that only reads a sentinel-bracketed
  consider would miss it (Q2).
- S&D records every name it scans or considers in **`SnDdb.db` `mobs`**
  (`mob, room, roomid, zone, seen_count, kill_count`). Your live DB holds
  19,804 name/room pairs across 6,297 rooms. That's history, not
  presence: mobs wander and die. At most it's a "usually here" hint, never
  a current occupant.
- Its `ht` (hunt trick) and `qw` (quick where) locate a target in the area,
  not the room's occupants; they're out of item 2's scope.

### 2.6 Our Consider feature today

It ships **with auto-refresh on by default** (`ConsiderSettings.enabled` and
`autoOnEntry` both `true`). It re-considers whenever the `{roomchars}`
signature changes, and that includes after each kill. Your October
recordings send no `consider` at all, so you have it switched off. A new
player gets it on. That runs against Areia's choice, and against your sense
that it's too expensive to have on by default.

## 3. Options

The model's job (D-129) is to record what exists and its handle, and to
say when it doesn't know. Two separate questions follow: what the model
*listens* to, and who *solicits* names.

### Q1 — What does the occupant entity hold?

- **(a) Presence plus named occupants when a name source has spoken.
  Recommended.**
  - `occupants`: from `{roomchars}`, holding flags, `isPlayer` and the
    description. It is always current while the feed is on.
  - `named`: the latest name list for **this room** (`room.info` num),
    with its source (`consider`/`scan`), its time, and per-mob name,
    flags, tier (consider only) and keyword from the one shared
    `ConsiderKeyword`. It is dropped on room change.
  - Pairing is by **count, not position**. When the named mob count equals
    `{roomchars}`'s non-player count, the list is "complete"; otherwise it is
    "partial" (someone arrived, died, or is hidden). Nothing guesses which
    description is which name.
- **(b) Presence only.** Names stay inside Consider; the model has no
  handle for occupants until a later item. That's simplest, but item 2 then
  doesn't deliver its entity's handle.
- **(c) Keyword guessed from descriptions.** **Rejected** on §2.1's
  evidence: 56% misses, and a wrong keyword attacks the wrong mob.

### Q2 — Which name sources does the model listen to? (passive; switches nothing on)

- **(a) Consider output from any sender, plus `{scan}`'s `Right here you
  see:` section. Recommended.**
  - The consider window opens on an **outbound** `consider`/`con` command,
    whoever sends it: the player, the Consider feature, or S&D's smartscan
    fallback (§2.5). It closes on the blank line or prompt that S&D's
    `consider_end` uses. The 14 patterns run only inside the window, so
    the per-line cost outside it is unchanged.
  - This reaches every S&D smartscan user's fallback considers for free.
  - **To verify before code:** that the engine sees outbound commands from
    every source (input, aliases, the S&D host) at one seam. If it
    doesn't, the fallback is a sentinel bracket, which only catches
    considers we send.
  - `{scan}` is a tag block item 1 can already collect. It needs D-129
    (2) read as "adjacent rooms are out; the current room's scan section
    is in". Because scan misses noscan mobs, a scan-only named list is
    "complete" only when the count check agrees.
- **(b) `consider` only.** This keeps `{scan}` wholly out per D-129 (2),
  at the price of ignoring names S&D's smartscan already delivers on every
  `nx`/`go` arrival.
- **(d) Also S&D's `mobs` table as a "usually here" hint.** It's
  read-only, like the keyword exceptions we already read. It is history,
  not presence, so it never fills `named`; at most the inspector or a
  future lens could show it marked as a hint. Not recommended for item 2.
- **(c) Also arrival and departure prose,** to keep names current between
  considers. The Consider model already does this for its own list. In the
  shared model it would be prose matching on every line, which the feeds
  doc ranks last, and the count check in Q1 (a) already reports "partial".
  Not recommended for item 2.

### Q3 — Who solicits, and when? (the Consider feature, as owner, D-123)

> **Revised after the first live test (§10):** auto-refresh is on by
> default again, with Areia's zone switch-off as an opt-in mode.

- **(a) On demand by default; auto opt-in with Areia's guards.
  Recommended.**
  - **Default:** `conw` or the panel's refresh button.
  - **Auto (`conw auto entry on`):** fires on room entry. It never fires
    while running or mid-speedwalk, nor in safe rooms. It turns itself off
    on a zone change, as Areia's does.
  - **No more re-considering after each kill:** kill and flee prose
    already update the list.
  - **No duplicate considers:** if the model already holds a
    consider-sourced list for this room (from S&D's smartscan fallback, say),
    the feature uses it instead of sending its own.
  - **Sentinel:** kept as today if Q2 (a)'s outbound-command window
    works. It moves to Areia's bracket shape (`echo {consider}` …
    `echo {/consider}`) only if the model has to fall back to bracketed
    considers.
  - **Also:** adds the two unattackable lines (divine protection, shopkeeper)
    from S&D, so the panel and `conwall` never target them.
  - **Impact:** this is a user-visible default change for a shipped
    feature, and existing players with saved settings keep theirs.
- **(b) Keep today's default (auto on),** add only the zone guard and the
  bracket. This preserves current behaviour, but keeps the cost you're
  wary of for every new player.
- **(c) Solicit `scan` instead of `consider`.** It's tagged and gives names
  and flags, but no difficulty tier. The tier is the point of the Consider
  panel ("handle combat selectively"), so it's not recommended as the
  primary. It could be a fallback if `consider` turns out to carry a wait
  state (§2.3).

**Keyword style** (a sub-question, settled later if you prefer): keep
`gmkw` (first and last word, 5-letter prefixes, S&D's exceptions table),
which is what we have and what S&D users' overrides are keyed for. Areia's
all-words `'w1 w2 w3'` is stricter (every word must match), which is the
cause of its "male villager" example. I recommend keeping `gmkw`.

### Q4 — Player keyword overrides (added 2026-10-30)

The iOS journey you described: the mob list shows, a tap attacks, and the
player can **set a keyword** for a mob that replaces whatever we had. It's
S&D's `xset kw` and Areia's `ac keywords`, and it will be needed. It should
be in the model from item 2, not bolted on later.

**What exists today:**

- S&D keeps overrides in `SnDdb.db` `mob_keyword_exceptions` (`area_name`,
  `mob_name`, `keyword`, unique per area and name). `xset kw` writes a row,
  its `gmkw` reads one per lookup, and its database rebuild deletes them
  all. Your Proteles copy holds 448 rows: S&D's seeded list plus your own,
  with no column saying which is which.
- We read that table read-only at connect (`ConsiderKeyword.loadExceptions`).
  **Proteles has no override of its own.**
- **A latent bug, measured:** our lookup matches the name exactly, but
  `consider` capitalises a name that starts its sentence ("A kobold knight
  looks a little worried…") while the table stores "a kobold knight". In
  the 3 recordings where Consider ran, **1** considered name matched an
  exception exactly and **211 more matched only ignoring case**. So the
  shipped feature almost never uses S&D's keywords. (I matched names only,
  not areas, so 211 is an upper bound.)

**The resolution chain**, in the shared resolver (the promoted
`ConsiderKeyword`):

1. The **player's override** for this area and name.
2. **S&D's exception** for this area and name, when S&D's database exists.
3. **The `gmkw` guess.**

Names match **ignoring case** at every step, which fixes the bug above;
the test must fail without the fix. Each named occupant carries its keyword
and **where it came from** (`player`, `snd` or `guess`), so a surface can
show "guessed" differently from "set by you" and offer the edit where it
matters.

**Where overrides live:**

- **(a) A Proteles-owned store; S&D's table stays read-only.
  Recommended.**
  - **Form:** a small table in the shared Databases folder, keyed by area
    and lowercased name, with keyword and date. It travels with the rest
    of the config (iCloud import, IOS_PORT_PLAN §2.4).
  - **Why not S&D's database:** S&D's place on iOS is still an open
    question (IOS_PORT_PLAN open question 3), so overrides can't depend
    on it. It also honours D-129: *"The Mapper, `GMCPState`, `ChatStore`
    and S&D keep owning their data; the model references them rather than
    copying."*
  - **Cost:** S&D's own targeting (`xcp`, `kk`) doesn't see a keyword set
    in Proteles. Setting it again with `xset kw` covers that.
- **(b) Write overrides into S&D's table.** One truth, and S&D's targeting
  agrees at once. But it writes another plugin's data (against D-129's
  ownership line), it doesn't exist without S&D (iOS), and S&D's database
  rebuild wipes it.
- **(c) (a), plus mirroring each override into S&D's table when present.**
  It agrees everywhere, but it is still a write into S&D's data, so it
  needs your explicit say against the D-129 text quoted above. It could be
  a later, opt-in step.

**How the player sets one, in item 2** (lens UI is I6, so no tap-to-edit
screen yet):

- `conw kw <n> <keyword>` sets an override for mob *n* in the Consider
  list; `conw kw <n>` with no keyword clears it.
- Consider's panel and the State inspector show each keyword's source.
- The model offers a single **set/clear override** effect, so a later
  macOS row action or the iOS lens adds only the gesture, not new
  plumbing.
- A changed override re-resolves the current named list and reports an
  occupants change.

## 4. What changes under the recommendations (Q1 a, Q2 a, Q3 a, Q4 a)

**MudCore, `Semantic/State/`:**

- `Occupant` (flags, `isPlayer`, description, lineID) and
  `OccupantLine.parse`, from completed `{roomchars}` blocks.
- `NamedOccupant` (name, flags, tier when the source is consider,
  keyword) and the parsers for a consider window (opened by an outbound
  consider, §3 Q2) and the `Right here` section of `{scan}`. The 14 consider patterns are shared
  with the Consider model, not copied.
- `ActionableState.occupants: Occupants?`, with `nil` meaning not seen. It
  holds `present: [Occupant]`, `mobs`, and
  `named: NamedList?` (source, room, time, mobs, and `complete` from the
  count check).
- `ActionableState.Feed` gains `scan` (tag block) and `consider` (a
  command-opened window, kind `solicited`). The inspector lists both.
- `Entity.occupants`, reported only when presence or the named list
  actually changes (heartbeat-identical blocks change nothing).
- `ConsiderKeyword` moves here as the shared resolver, with case-insensitive
  name matching and the player-override layer (Q4). `NamedOccupant`
  carries `keywordSource`.
- `MobKeywordOverrides`: the Proteles-owned store (Q4 a), read on connect,
  written by the set/clear effect.

**`ConsiderFeature`** (the consumer):

- It reads occupants from the model for its refresh signal, and drops its
  own `{roomchars}` buffering.
- It solicits per Q3 (a).
- Its list, panel, `conw`/`conwall` and batch filter stay as they are.

**State inspector:** an Occupants section, holding the mob descriptions
with flags, "players present: N" (no player names), and the named list with
source, age and complete or partial.

**Replay:** pins gain occupant and named counts. New invariants: no
`(P)`/`(Player)` occupant ever counts as a mob, and every named list
belongs to the room it was taken in.

**`docs/STATE_MODEL.md`** starts with its first entry: occupants.

## 5. What does not change

- No tag family is switched on (D-123). The model only reads considers
  that someone else sent; the Consider feature solicits as it already
  does.
- Adjacent-room scan sections (`North from here …`) stay out (#91).
- No player names anywhere in the model.
- No automatic attacking, ever.

## 6. Impact and measurement

The per-line path is unchanged: `{roomchars}` and `{scan}` are blocks
item 1 already collects, and the consider patterns run only inside a
consider window.

- **B6 A/B** against a same-day Release control at `c21c041a`. Over
  +20 ns per line gets reported before handover.
- **B6b** gains per-block figures.
- **Live checks only you can do:** the Consider defaults (§3 Q3), auto mode
  with the zone guard, and a mob with divine protection.

## 7. Facts settled in game (2026-10-30, `session-20261030-105618`)

1. **Wait state:** about 0.33 s on the next command (§2.3). That's small.
   Auto mode is still a cost multiplied by every room entered, which is
   why on demand stays the recommended default.
2. **`commandtags`:** not supported by `consider` (§2.3).
3. **Auras** (`help auras`):
   - Short and long pairs: `(Animated)` A, `(Charmed)` C, `(Diseased)` D,
     `(Flying)` F, `(Golden Aura)` G, `(Hidden)` H, `(Invis)` I,
     `(Marked)` X, `(Player)` P, `(Red Aura)` R, `(Stealth)` S,
     `(Translucent)` T, `(Undead)` U, `(White Aura)` W.
   - Long form only: `(Angry)`, `(OPK)`, `(Wounded)`.
   - The recordings also show `(Linkdead)`, `(Joyful)` and `(HARDCORE)`,
     which aren't in the help, so the parser keeps unknown flags as text
     rather than rejecting the line.
   - Item 2 interprets only `P` and `Player` (never a target). The rest
     stay text for the Consider batch filter, which already reads
     `W`/`G`/`R`.

## 8. Implementation notes (2026-10-30)

Where the code differs in detail from §4, and why:

- **Occupant has no `lineID`.** Equality is by flags and description, so
  the heartbeat's identical blocks compare equal and wake no plugin.
- **`present` is optional.** A name list can arrive before any
  `{roomchars}` (feed off). An empty `present` would read as "nobody
  here", so presence stays `nil` (unknown) until the block arrives.
- **A second entity, `.keywords`.** It is reported when the book loads on
  connect and when an override changes. A keyword change on its own (no
  names in the room) still reaches the Consider feature, which re-keys its
  list.
- **`room.info` is decoded in the tracker** (`ingest(gmcpPackage:json:)`),
  so the engine and the replay share one path.
- **The consider window** opens in `SessionController.sendLine`, before the
  bytes leave. That's the one point every command passes: typed input,
  aliases, plugin effects, S&D, autologin. `OnPluginSend` isn't
  universal (typed input that skips the plugin layer never reaches it).
  - **Opens on:** `con`, `cons`, … `consider`, bare or with `all`.
  - **Before the run:** lines are skipped until the first consider line.
  - **Ends at:** the first other line after a consider line (the prompt).
    "You see no one here but yourself!" ends it with an empty list; a
    safe-room refusal ends it with no list.
  - **Give-up:** each send waits at most 20 s for its first consider
    line, on its own clock; runs answer sends oldest first. There's no
    line limit: the first corpus replay found a consider sent mid-speedwalk
    answered after 1,435 lines (8 s), and an unanswered send's clock ending
    the next send's run. Those lost 30 runs in one session
    (`session-20260821-131406`); with per-send clocks the reader takes
    every answered consider in the 166 sessions that sent one.
  - **Cost:** while a window is open, each line pays one literal-substring
    prefilter before any regex.
- **Consider feature details under Q3 (a):**
  - Combat-end re-consider (`conw auto combat`) now defaults off. A room
    entered mid-fight is still considered when the fight ends.
  - Entering a room clears the list unless a run is in flight. With auto
    off, the old room's list would otherwise linger.
- **Shared patterns:**
  - `ConsiderTier` moved to `Semantic/State/ConsiderTier.swift`.
  - `ConsiderLine` is the one consider-line matcher, used by both the
    model and `ConsiderModel`.
  - The unattackable patterns are S&D's two triggers plus the popular
    consider plugin's other three (`Aardwolf_Consider_Miniwin.xml`): a
    god's disapproval or smiting, and "has already been challenged". Each
    is one mob in the list. The challenge line is the common one (183 in
    the recordings, usually mid-list), and ended runs early before. The
    game prints it on attack too, so it can open a run when it arrives
    first; in the corpus, all 34 runs made only of unattackable lines
    are genuine consider answers (about 0.2 s after the send).
- **Keyword overrides** live in `~/Documents/Proteles/Databases/MobKeywords.db`
  (`mob_keyword_overrides`).
- **The panel shows a keyword's source in its tooltip,** with the `conw kw`
  hint. No new visible badge: a visible marker is a lens decision.
- **Replay:** the `.jsonl` holds inbound bytes only, so the replay reads
  each `.log`'s `SEND` lines (memory-mapped; `SEND` must follow the
  timestamp directly) and opens the window at the same point in the byte
  stream.

## 9. Measurement (2026-10-30)

B6 (`ScriptEngine.process` per line, the largest recording, 1,254,793
lines), Release, run alternately against a same-day control at
`c21c041a` (item 1):

| B6, ns per line | Control | Change |
|---|---|---|
| First build | 1,064–1,080 | 1,211–1,228 |
| Per-line check on a stored flag | 1,060–1,063 | 1,065–1,068 |

**The first build was +150 ns per line, and it wasn't the new logic.**
B6b, the tracker alone, moved only from 63 to 92 ns per line. The rest came
from the engine's per-line guard, `stateTracker.mayChange(on:)`. That is a
method call on a struct stored in the actor, which copies the tracker every
line, and item 2 gave the tracker more heap-backed fields to retain and
release.
- **The fix:** the guard now reads two stored fields directly: the line's
  first byte, and `isReading` (a block or consider window is open), which
  the tracker keeps current. A stored field is read without copying.
- **The result:** +4 ns, within noise.
- **Item 1 too:** item 1's frame paid the same copy, a smaller one with
  fewer fields, so part of its +98 ns (§10 of the item 1 proposal) was
  probably this.

B6b with the change: about 16 ns per non-tag line (unchanged) and about
640 ns per tag line, against about 420 ns before. The difference is the
`{roomchars}` and `{scan}` parses, and the occupant comparison, once per
completed block. The consider window's prefilter isn't in either figure:
B6 sends no commands, so no window opens. It costs only between a consider
being sent and its prompt.

## 10. After the first live test (2026-10-31, `session-20261031-065653`)

**Killed mobs came back to life.** Saved settings kept the old
re-consider-on-combat-end switch on. At each fight's end, the
feature's "use the list the model already holds" path reloaded the
list taken on entering the room, which predated the kills. The game sends
the combat-end `char.status` 3 ms before the kill line, so each kill
marked its mob dead and revived the ones before it.
- **The fix:** an automatic refresh reloads a list only when someone else
  took it after ours; otherwise it sends a new consider.
- **Combat end:** the switch is gone. Kill, flee and movement lines keep
  the list current, and a mob arriving mid-fight queues one refresh for
  when the fight ends.

**Q3 revised: on by default, three modes** (`conw on|area|off`). On a
phone, typing `conw on` in every new area cost more than the refresh did.
- **`on`:** the default. It refreshes on entering a room, when a mob
  arrives or flees (the original's `auto_consider_misc` group), and when
  the area repops (Areia's `comm.repop`).
- **`area`:** Areia's rule. It switches off on leaving the zone, and says so.
- **`off`:** on demand.
- **What doesn't fire it:** nothing fires mid-combat (it waits), while
  running, or in a safe room; only one consider is in flight at a time.
- **Saved settings:** those from before the modes become `on` when
  auto-refresh on entry was on, else `off`.
- **Each command says what it did.**

**Movement without a verb list.** The original's 19 verbs each way miss
most of what the recordings hold: swoops 858, flutters 396, flits 362,
then waddles, stomps, slithers, marches, plods, prowls, sloshes, pads,
crawls and sneaks.
- **Leaving:** `<name> <verb> <exit>.`, acted on only when the name is a mob
  on the list, so `Your mental barrier breaks down.` is ignored.
- **Arriving:** `<name> <verb> in from [the] <direction>.`, `arrives from`,
  or `appears in the room`.
- **Thunderclaps** (`With a thunderclap, Turnus appears in the room.`): all
  109 such names in the recordings are players, so they're ignored.
- **Not distinguished:** players who walk or fly in (`Turnus flies in from
  above.`) can't be told from mobs by the line. In auto mode, the refresh
  they trigger replaces their row.
- **A departed mob is drawn dimmed** with where it went (`left south`,
  `fled`). It's no longer struck through like a dead one.

**Not done: pausing while the mapper walks.** Areia's plugin also waits
while the mapper broadcasts `kinda_busy`, since `char.status` can read 3
for the first room of a run. Our mapper sends `{end running}` only with a
walk's final segment, so an abandoned walk never clears the flag (250
begins against 222 ends in `session-20261031-065653`). A gate on it would
stick, so it waits for the mapper to match the reference, which always
sends the end marker.


## 11. Pausing while the mapper walks (2026-11-22)

The mapper now ends every walk it begins (`9b0d3ca9`), so the gate above was
built. A live campaign run (`session-20261121-084649`) showed why it matters:
a consider sent mid-walk queues behind the `run` and is answered in the
room the walk ends in. On the way to a campaign mob, each leg sent one, and
all three answers arrived in the mob's room (09:42:34–39), each followed by
Search-and-Destroy reprinting its target list.

- **The signal:** the mapper's 999 broadcast now reaches native plugins
  (`NativePlugin.onMapperBroadcast`), not only Lua ones.
- **The rule:** a refresh that falls due while `kinda_busy` is held, and one
  goes out on `ok_you_can_go_now`. Areia's plugin only holds; but the end
  arrives about 0.1 s after the destination room (0.00–0.21 s over 131
  walks), always after the state is back to 3, so holding alone would also
  drop the consider in the room the walk was for.
- **Measured:** replaying that session from `conw on`, 179 considers become
  85. Live afterwards (`session-20261124-074839`, `conw on` for 35 minutes),
  none of 102 walks sent a consider mid-walk, and 70 sent exactly one after.
