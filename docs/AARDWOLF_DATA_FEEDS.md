# Aardwolf data feeds — what is durable, what is configurable

> **Purpose.** The semantic layer (S0a, #82) and the actionable-state model
> (S0b, #84) both have to answer one question about every piece of information:
> *where does this come from, and can the player change its shape?* This
> document is the measured answer. It exists because much of Aardwolf's raw
> output is player-configurable in-game, which makes line-pattern matching
> fragile in a way that is invisible until someone else's config differs from
> yours.
>
> **Everything here is measured or quoted**, not inferred: counts come from
> local session recordings (`~/Documents/Proteles/Recordings`, ~51 sessions),
> semantics come from in-game help files captured in
> `session-20260822-141044.log`. Where something is still unknown it is listed
> in §7 rather than guessed at.

## 1. The ordering rule

**GMCP > tags > line patterns.** Prefer the highest tier that carries the
information. Where a pattern is unavoidable, mark it as a fallback, record which
configuration it assumes, and cover it with a transcript test.

| Tier | Stability | Why |
|---|---|---|
| **GMCP** | Structural | A parsed protocol. Unaffected by every setting in §2. |
| **Tags** | Structural, but opt-in | `{name}…{/name}` blocks. Shape is fixed; *availability* is not (§3). |
| **Line patterns** | Fragile | Subject to every axis in §2, per player. |

## 2. Configurability axes — what can change under us

Each of these changes the raw stream without changing the game state.

**`damage 0–6` — seven combat output modes** (`help damage`). Regular one line
per hit; total or average per round; basic or regular or "very short basic"; per
damage type. The same fight produces structurally different text in each.
Aardwolf itself documents cases that *don't* combine even when combining is on:
immunity messages, complete misses, `charge`, counter-strike and reflected
damage, auto-damage (Gaias, Test of Faith), multi-spell scrolls, and
rainbow/prismatic spray.

*Consequence: combat damage cannot be classified reliably from lines alone. See
§5 for what is durable instead.*

**`shortflags` — flag rendering** (`help auras`). Aura flags render either short
(`(P)`) or long (`(Player)`). Both forms must parse. Note `(Angry)` has **no
short form** — it is always long.

**`prompt` / `promptflag`** — the prompt is fully user-composed. Never parse
vitals from it; `char.vitals` carries them (§4).

**`spamreduce`** (`help spamreduce`, `help spam2`) — a whole suppression system
with save/restore. Options remove entire message classes from the stream (e.g.
`areaspells`). **A missing line may mean "did not happen" *or* "suppressed".**

**Individual toggles that reshape lines we care about** (`help spam2`,
`config all`):

| Toggle | Effect on parsing |
|---|---|
| `noobjlevel` | Drops levels after object descriptions — changes `{roomobjs}` and inventory lines |
| `nopretitle` | Hides player pretitles — changes `{roomchars}` occupant lines |
| `brief` | Room descriptions only on first entry — `{rdesc}` becomes intermittent |
| `info` | Controls which `INFO:` messages display — **the soundpack keys off `^INFO: .+$`** |
| `echodeaths`, `nowar`, `noweather` | Remove whole message classes |
| `healtype` | Combines heal messages |
| `catchtells` | Defers tells to `replay` |
| `promptflag` | Removes quiet/afk/noexp flags from the prompt |
| `channels` / `quiet` | Silence channels wholesale |

**`tags <family> on|off`** — see §3.

## 3. Tags: availability is not guaranteed, and enabling has a cost

Per `help tags`: `tags` alone lists available families; `tags <option> on|off`
controls one; `tags off` / `tags quiet` silences all.

**Two things to design around:**

1. **Enabling tags disables the game's scroll/paging** — quoted: *"If tags are
   enabled, scroll will be disabled, to prevent any interference from paging
   prompts."* Not free.
2. **Nobody enables most of them today.** Measured from recording SEND lines,
   the only families anything of ours turns on are:
   - **Proteles** → `tags exits on` (behind an opt-in preference, for RichExits)
   - **Search-and-Destroy** → `tags roomchars on`, `tags scan on`

   Everything else present in the recordings is on because *this player* enabled
   it in-game. A feature built on `{roomobjs}` would be silently empty for
   anyone else.

**Decision (2026-08-22): Proteles enables the tag families a feature needs, per
feature, explicitly and reversibly** — extending the existing `tags exits on`
precedent. A feature must own its feed rather than assume it, and must not
silently show an empty surface.

### The authoritative family list

From the bare `tags` command. **Status is this player's current setting**, not a
default — the point of the column is that a feature cannot assume any of it.

| Family | Emits | Status |
|---|---|---|
| `BIGMAP` | `{BIGMAP}` | on |
| `CHANNELS` | `{chan ch=name}` | **off** |
| `COORDS` | `{coords}` | on |
| `EDITORS` | `{edit/}` | off |
| `EQUIP` | `{equip/}` — own equipment | **off** |
| `EXITS` | `{exits}` | on |
| `HELPS` | help + help headers | on |
| `INV` | `{inventory/}` — own inventory | **off** |
| `MAP` | `<MAPSTART>` / `<MAPEND>` | on |
| `MAPEXITS` / `MAPNAMES` | exits / room name inside map tags | on |
| `QUIET` | silences all other tags | off |
| `ROOMDESCS` | `{rdesc}` | on |
| `ROOMNAMES` | `{rname}` | on |
| `SAYS` | `{say}` | **off** |
| `SCORE` | `{score}` | off |
| `SKILLGAINS` | skill gain/increase | on |
| `SPELLUPS` | `{affon}` `{affoff}` `{recon}` `{recoff}` `{sfail}` | on |
| `TELLS` | `{tell}` | **off** |
| `TELOPTS` | client auto-set flags | off |
| `ROOMCHARS` | `{roomchars}` | on |
| `ROOMOBJS` | `{roomobjs}` | on |
| `SCAN` | `{scan}` | on |
| `REPOP` | repop messages | off |
| `COMMANDS` | game commands (TEST only) | off |
| `WHERE` | `where` output | off |
| `MAPDATA` | experimental, does nothing yet | off |

**`CHANNELS`, `TELLS` and `SAYS` are all off** — and those are exactly the three
S0a's tag-family router was scoped to start with (#82). The router work therefore
*begins* with enabling them, and must handle their absence.

### `commandtags` — the non-persistent alternative

Per `help commandtags`, some commands take a `tags` argument (`rank 1 tags`)
which wraps that one command's output in tags **and** disables paging for it,
without touching any global setting. For one-shot queries this is strictly
better than flipping a family on: no permanent scroll loss, no change to what
the player sees the rest of the session. Prefer it wherever the data is pulled
rather than streamed.

Families with their own semantics: `help invdata`, `help spelltags`,
`help telltags` (note: enabling `TELLS` also *changes tell behaviour* — tells
are shown tagged even when they did not go through, e.g. "You tell Ivar
(Ignored)", and deferred tells store to the replay buffer).

## 4. Measured feed inventory

From `session-20260819-084313.log` (138 MB, 599,850 `RECV` lines, one session).
Counts are *this* session — they establish presence and rough frequency, not a
universal ratio.

### GMCP packages received

| Package | Count | Carries |
|---|---|---|
| `char.vitals` | 24,256 | `hp`, `mana`, `moves` |
| `char.status` | 22,370 | `level`, `tnl`, `hunger`, `thirst`, `align`, **`state`**, **`pos`**, **`enemy`** |
| `room.info` | 10,811 | room identity, zone, exits |
| `char.worth` | 2,508 | currency/qp |
| `char.stats` | 1,949 | trainables, hitroll, damroll |
| `group` | 1,620 | group membership/state |
| `comm.tick` | 1,618 | tick timing |
| `config` | 1,459 | server-side config echo |
| `comm.channel` | 1,076 | channel messages |
| `char.maxstats` | 936 | maxima |
| `comm.quest` | 113 | quest lifecycle |
| `char.base` | 105 | identity |
| `comm.repop` | 99 | zone repop |
| `room.wrongdir` | ~27 | **a move failed** — *not currently handled by us* |

### Tag families observed

| Tag | Blocks/lines | Carries |
|---|---|---|
| `{coords}` | 21,626 | map coordinates (machine data) |
| `{invmon}` | 12,360 | inventory add/remove events |
| `{rname}` | 10,808 | room name |
| `{roomobjs}` | 10,554 | **items on the floor** |
| `{roomchars}` | 10,554 | **occupants — mobs and players** |
| `{rdesc}` | 5,754 | room description |
| `{exits}` | 5,277 | exits |
| `{affon}` / `{affoff}` | 4,148 / 4,146 | **affects on/off, by numeric spell id** |
| `{invitem}` | 2,068 | single-item detail |
| `{scan}` | 1,338 | occupants of adjacent rooms |
| `{skillgain}` / `{sfail}` | 398 / 282 | skill improvement / failure |
| `{invdata}` | 80 | full inventory dump |
| `{spellheaders}` | 22 | spell list headers |

Observed shapes:

```
{roomobjs}
     (M)(G)(H)(N) A nondescript key lies here on the ground.
{/roomobjs}
{roomchars}
(P)(F)(W) (OPK) Tinada the Chronicler [R/C].
(F) Reflection of Radience
{/roomchars}
```

```
{affoff}259
{affon}259,2655
```

### The spell/skill model — `slist` and the spellup tags

`SPELLUPS` (on) emits a complete, structured spell lifecycle (`help spelltags`):

| Tag | Shape | Meaning |
|---|---|---|
| `{affon}` | `72,1650` | spell 72 landed, lasts 1650s |
| `{affoff}` | `72` | spell 72 wore off |
| `{recon}` | `15,1200` | recovery (cooldown) 15 started, 1200s |
| `{recoff}` | `15` | recovery 15 expired |
| `{sfail}` | `72,0,2,-1` | spell#, target (0=self/1=other), reason, recovery# |

`{sfail}` reasons: 1 lost concentration · **2 already affected** · **3 blocked by
a recovery** · **4 not enough mana** · 5 nocast room · 6 fighting/can't
concentrate · 8 don't know it · 9 self-only cast on other · 10 resting/sitting ·
11 disabled · 12 not enough moves.

Reasons 2, 3 and 4 are precisely the "pick a different spell" signals in the
combat journey — they say *why* a cast failed, structurally.

**`slist` resolves the ids**, and much more. CSV inside `{spellheaders}`:

```
SN, Name, target, duration, Pct, recovery, type
97,adrenaline control,3,1725,97,-1,1
320,acid stream,1,0,95,-1,1
```

| Field | Meaning |
|---|---|
| `SN` | spell number — **the id in `{affon}` / `{affoff}` / `{sfail}`** |
| `Name` | skill/spell name |
| `Target` | 0 special · **1 attack** · **2 spellup** · 3 self-only · 4 object · 5 extended syntax |
| `Duration` | seconds remaining if currently affected, else 0 |
| `Pct` | percent practiced |
| `Recovery` | recovery number this relies on, or `-1` |
| `Type` | 1 spell · 2 skill |

So one `slist` call yields the id→name map, **which spells are attacks versus
spellups**, what is currently active and for how long, what is practiced enough
to be worth casting, and cooldown linkage. `slist learned` / `slist affected` /
`slist recoveries` narrow it. This is the backbone of any cast/spellup surface —
no line parsing required.

### Aura flags (`help auras`)

The mob-versus-player discriminator, needed so a targeting surface never offers
to attack a player:

| Flag | Short | Meaning |
|---|---|---|
| `(Player)` | `P` | **Not a mob.** The discriminator. |
| `(Angry)` | *none* | Aggressive mob sensing anger |
| `(Charmed)` | `C` | Under someone's command — a pet |
| `(Golden Aura)` / `(Red Aura)` | `G` / `R` | Good / evil alignment (affects xp) |
| `(Hidden)` / `(Invis)` | `H` / `I` | Detected but concealed |
| `(Marked)` | `X` | More vulnerable to attack |
| `(Flying)`, `(Translucent)`, `(Undead)`, `(Animated)`, `(Diseased)`, `(Stealth)`, `(White Aura)` | `F`, `T`, `U`, `A`, `D`, `S`, `W` | see `help auras` |
| `(OPK)` | *none* | Open player-kill opt-in |

Object flags are a separate table — `help object flags`, `help weapon flags`.

## 5. Combat: what is durable

Given `damage 0–6`, the reliable signals are **not** the damage lines:

- **Am I fighting, and with whom** — `char.status.state` and
  `char.status.enemy`. `enemy` is empty when not in combat.
- **My vitals** — `char.vitals`, never the prompt.
- **Enemy health %** — already parsed from GMCP (`GMCPModules.swift`).
- **Damage magnitude, when a line must be read** — the damage verbs are a
  **fixed ordered ladder** (`help damage verbs`): `misses, tickles, bruises,
  scratches, grazes, nicks, scars, hits, injures, wounds, mauls, maims, mangles,
  mars, LACERATES, DECIMATES, DEVASTATES, …` ascending. Ordinal position is a
  stable magnitude proxy across settings, where the numeric total is not.

`char.status.state` — the authoritative table, from Aardwolf's GMCP wiki
(`help GMCP` points there; the codes are not documented in-game):

| Value | Meaning |
|---|---|
| 1 | Login screen, no player yet |
| 2 | MOTD / login sequence |
| 3 | **Fully active, accepting commands** |
| 4 | AFK |
| 5 | In a note |
| 6 | Building / edit mode |
| 7 | At a paged-output prompt |
| 8 | **In combat** |
| 9 | Sleeping |
| 11 | Resting or sitting |
| 12 | Running |

`char.status` also carries `enemypct` alongside `enemy`.

**Finding — `isSafeToInterrupt` looks incomplete.** `GMCPModules.swift` treats
only 8 (combat), 12 (running) and 5 (note) as unsafe. Against the full table, **7
(paged-output prompt)** and **6 (building/edit)** are arguably just as unsafe to
interrupt with an update prompt, and 9 (sleeping) is worth a thought. Those three
values were inferred from usage before the table was available, and the
inferences were right as far as they went — they were simply incomplete. Not
changed here; flagged for whoever touches #42's machinery next.

## 6. Entity → feed map (S0b input)

| Entity | Durable feed | Status |
|---|---|---|
| Occupants (mobs, players) | `{roomchars}` + `help auras` flags | parsed, but private to `ConsiderFeature` |
| **Targetable keyword** | `ConsiderKeyword` (native port of S&D `gmkw`: curated `SnDdb.db` exceptions, then stop-word strip → per-area regex → first+last word → 5-char prefix) | exists, private to Consider |
| Items on the floor | `{roomobjs}` | parsed by nothing |
| Exits | `{exits}` + `room.info` | available |
| Custom exits / arbitrary room | Mapper DB | available |
| Adjacent-room occupants | `{scan}` | S&D enables it; unused by us |
| Vitals | `char.vitals` | available |
| Combat state / current enemy | `char.status` | available |
| Affects (spellups) | `{affon}` / `{affoff}` + `slist` for names | available; ids resolve via `slist` |
| Spell/skill book (attack vs spellup, practiced %, cooldowns) | `slist` | available, unused |
| Cast failure reason (immune, already up, no mana, cooldown) | `{sfail}` | available, unused |
| Cooldowns | `{recon}` / `{recoff}` + `slist recoveries` | available, unused |
| Inventory / worn / bags | `{invdata}` / `{invitem}` / `{invmon}`, dinv | inside a Lua plugin |
| Portals | dinv | inside a Lua plugin |
| Target list | S&D `targets_as_json` | reachable only from Lua |
| Channels | `comm.channel` + `ChatStore` | available |
| Group | `group` GMCP | available |
| Failed movement | `room.wrongdir` | **not handled** |

The recurring shape: most feeds **exist and are parsed already**, each behind a
single private consumer. S0b is mostly promotion and unification.

## 7. Open questions

**Resolved 2026-08-22** — the first round of requests came back and is folded in
above: the authoritative tag family list (§3), the `char.status.state` table
(§5, from the GMCP wiki since it is not in-game), the spellup tag semantics and
`{sfail}` reason codes (§4), the `slist` spell model that resolves affect ids
(§4), `commandtags` as a non-persistent alternative to global tag families (§3),
`shortflags` confirmed, and the `spam2` toggle list (§2).

**Still open:**

1. **Damage output under settings other than the player's current one.** §2
   documents that `damage 0–6` produce structurally different combat text, but
   the recordings only contain *one* setting. Any combat-line parsing needs
   captures under at least a second setting before it can claim to handle them —
   see §8. Cheapest path: switch `damage`, fight briefly, switch back.
2. **`{roomobjs}` / `{roomchars}` under `noobjlevel` and `nopretitle`.** Both
   toggles reshape exactly the lines a floor-items or occupants surface parses,
   and the current captures are from one configuration.
3. **Object flag letter forms are undocumented — do not guess them.**
   `help auras` gives mob flags *with* their single-letter short forms
   (`(Player)` → `P`). **`help object flags` gives full names only**, marking
   displayed flags with `*` but never stating the letters. So the observed
   `(M)(G)(H)(N)` on a `{roomobjs}` line is ambiguous: `M` could be `Magic` or
   `Melt-drop*`; `N` could be `Nodrop`, `Nosell`, `Nolocate`, `Nosac`, `Nosave`
   … Any floor-items or inventory surface that renders flags needs this map
   first.

   *Cheapest way to resolve:* `shortflags off`, then look at a room with items on
   the ground (and/or a carried item), capturing the long-form flags — that gives
   the letter→name mapping directly from live output. `shortflags on` restores.

## 8. Test implications

Every claim in this document is a testable assertion, and should become one as
the corresponding feature lands:

- **Fixtures come from recordings, not from hand-written samples.** The
  recordings corpus is the ground truth; a hand-written line encodes the
  author's assumption about a format the player can change.
- **Configurable surfaces get more than one fixture.** Anything touching combat
  output should be tested against captures under more than one `damage` setting;
  anything parsing flags against both `shortflags` forms.
- **Tag-dependent features test the disabled path**, asserting the graceful
  outcome rather than an empty surface.
- **Feeds marked "unknown" in §7 must not be guessed.** A parser for `{affon}`
  ids without the name mapping is a parser encoding a hypothesis.
