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
`areaspells`). A missing line may mean "did not happen" *or* "suppressed".

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

Three families have their own semantics: `help invdata`, `help spelltags`,
`help telltags`. Some commands carry their own tag option — `help commandtags`.

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

Affects are **numeric spell ids**, not names — a name mapping is required before
an affects surface can label anything (§7).

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

Known `state` values, from our own code and the reference package:

| Value | Meaning | Source |
|---|---|---|
| 8 | Fighting | `GMCPModules.swift` |
| 12 | Running | `GMCPModules.swift` |
| 5 | Note mode | `GMCPModules.swift` |
| 3, 11 | Map requestable (3 also common at rest) | `aard_ASCII_map.xml` |
| 2 | *unknown* | — |

**The full table is an open question (§7)** — these were inferred from usage,
not read from a spec, so they are marked accordingly.

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
| Affects (spellups) | `{affon}` / `{affoff}` (ids) | needs id→name map |
| Inventory / worn / bags | `{invdata}` / `{invitem}` / `{invmon}`, dinv | inside a Lua plugin |
| Portals | dinv | inside a Lua plugin |
| Target list | S&D `targets_as_json` | reachable only from Lua |
| Channels | `comm.channel` + `ChatStore` | available |
| Group | `group` GMCP | available |
| Failed movement | `room.wrongdir` | **not handled** |

The recurring shape: most feeds **exist and are parsed already**, each behind a
single private consumer. S0b is mostly promotion and unification.

## 7. Open questions — help files still needed

Requested, in priority order:

1. **`tags`** (bare command, no argument) — the authoritative list of families.
   Everything in §4 is "what this player happens to have on"; this gives the
   real set.
2. **`help GMCP`** and **`help GMCPConfig`** — hoping for the `state` code table
   (§5) and the authoritative package list.
3. **`help Spelltags`**, **`help Telltags`**, **`help CommandTags`** — the three
   families `help tags` says have their own semantics.
4. **`help shortflags`** — confirm the exact toggle and both rendered forms.
5. **Spell id → name mapping** — `{affon}259` needs a name before an affects
   surface can label it. Unknown whether a help file, a command, or GMCP
   provides this.
6. **`help spam2`** — the full spam-suppression option list, to know which
   message classes can vanish.

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
