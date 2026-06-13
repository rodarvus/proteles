# Mapper command fidelity — bring our `mapper …` interface to MUSHclient parity

> **Status: shipped (feature-complete for 1.0; D-90, `v0.4.3`). Historical
> design doc — kept for the rationale and trade-offs.** All 8 phases landed
> across commits `dca6d0b`…`2d83109`, 1188 tests, four gates green. Deferred
> follow-ups + justified divergences are recorded in `../KNOWN_ISSUES.md`
> ("Mapper command-fidelity follow-ups"). The phase plan below is kept as the
> historical record. See `../DECISIONS.md` (D-90).

**Goal (user):** every `mapper` command should behave and *look* exactly like the
reference Aardwolf mapper (`submodules/aardwolfclientpackage/MUSHclient/lua/mapper.lua` +
`worlds/plugins/aard_GMCP_mapper.xml`), not "our way." Three acceptance bars:
1. **All** reference commands implemented.
2. **Behaving identically.**
3. **Output identical** (bordered ASCII tables, clickable rows, exact wording + colours).

**Decisions taken (user):**
- Full fidelity pass across everything.
- **Display-window** (`zoom`/`hide`/`show`/`updown`/`underlines`/`compact`/
  `quicklist`/`showroom`) and **multi-database** (`database`/`set database`/
  `backups`) commands are **mapped to native panel / app equivalents** — the
  command names keep working, routed to our native map panel + global-DB model
  rather than reproducing the MUSHclient miniwindow/multi-DB behaviour verbatim.

**Hard rule (NO-GUESSING):** every command's exact output strings, column
layouts, colours, and behaviour are read **from the reference** (`mapper.lua` /
`aard_GMCP_mapper.xml`) and the live DBs **at implementation time** — the audit
inventory below is a checklist, not the source of truth. When the reference is
ambiguous, ASK.

---

## The core problem

Our mapper is a native reimplementation (D-25/D-30) that prints **plain blue
`Note` lines** with our own wording and **no clickable rows**. The reference
prints **green mapper notes / red errors**, **bordered ASCII tables**, and
**clickable hyperlink rows** that dispatch `mapper goto <uid>`. So even the
commands we have don't match byte-for-byte. The linchpin of this whole effort is
a **faithful output layer** that every command routes through.

## Phase 0 — Faithful output layer (the foundation; everything depends on it)

Read the reference's output helpers and reproduce them in MudCore:
- **Colours:** `mapper.lua`'s note/error/table colours (`mapprint` green,
  `maperror` red, hyperlink + hover colours, the table fore/back). Map to our
  palette so output is the same colour as MUSHclient. (Read the exact config
  constants — don't guess the RGBs.)
- **`MapperOutput` builder** (pure, value-typed, in MudCore): emits
  `[ScriptEffect]` of coloured note lines, with helpers for
  `mapprint`/`maperror`, a **bordered table** (`+----+`, `string.format`-style
  fixed-width columns + headers + footer counts — monospace, so it renders), and
  **clickable rows**.
- **Clickable rows:** extend the mapper note path so a `NoteSegment` can carry a
  `LineLink` (D-40 `.sendCommand("mapper goto <uid>")`); today `.note`/
  `.colourNote` are link-less. This is the one structural addition; everything
  else is formatting.
- Unit tests: the table renderer produces the exact reference border/column
  layout for sample data; a clickable row carries the right command.

**Acceptance:** a side-by-side of one table command (e.g. `mapper areas`) against
a MUSHclient screenshot is indistinguishable (text + colour + click).

## Phase 1 — Navigation & path commands
`goto`, `walkto` (fix: reuse goto's pathing, differ only in status wording — not
"no portals"), `where` (the `printpath` format: `Path from X to Y is:\n<speedwalk>\nDistance: N`),
`findpath` (same `printpath` format), `resume` (last hyperlink/speedwalk),
`stop` (`Speedwalk cancelled.`), `next`. Match every status/error string.

## Phase 2 — Search commands (+ clickable)
`find` (distance-sorted **clickable** hyperlinks + intro/closing lines),
`list` (the distinct bordered FTS listing — `START/END OF SEARCH`, clickable),
`areas` (bordered keyword/Area Name/Explored table + `Found N areas containing M
rooms`), `area`, `shops`/`train`/`quest`/`heal` (special-info searches),
`unmapped` (bordered table by-area-count vs by-room-detail, clickable).

## Phase 3 — Portals & recalls
`portals` (bordered #/area/room/vnum/commands/lvl table, **clickable** when
`level ≥ portal.level`, the `*` bounce marker, red recall rows), `portal`
(recall auto-detect + level prompt + `PORTAL AUTO-DETECT …`), `fullportal`,
`delete portal`, `change portal {old}{new}` + `#N` form, `portalrecall`,
`portallevel`, `bounceportal`, `bouncerecall`, `purge portals` (**confirm step**).

## Phase 4 — Custom exits
`cexits` (bordered table, clickable), `cexit` (exact `CEXIT: WAIT FOR
CONFIRMATION …` + `Custom Exit CONFIRMED: from (cmd) -> to`), `fullcexit`,
`delete cexits`, `delete exits to|from <room>`, `cexit_wait` (set the delay we
currently hardcode), `lockexit`, `purge cexits [area]` (**confirm step**).

## Phase 5 — Room info, notes & flags
`thisroom` (the full bordered block: Name/ID/Area/Terrain/Info/Notes/Flags/
Exits/Exit locks/Ignore-mismatch), `notes`/`bookmarks` (reference = **edit the
current room's note** via a dialog — use our `proteles.dialog` provider, or the
`mapper notes <text>` arg form; exact `Note added to room X : text` messages),
`addnote`, `delete note`, `noportal`/`norecall` (reference `<room-id> true|false`
form), `ignore mismatch [area] true|false`.

> **Decision flag (resolved as shipped):** our original `mapper notes` *listed*
> all noted rooms — useful, but not what the reference does. Resolved by making
> `notes`/`bookmarks` match the reference (edit current) and keeping "list all
> notes" as a clearly-ours command.

## Phase 6 — Areas, zones & maintenance
`purgezone` (`Purged <area> from the mapper database` + the syntax help),
`purgeroom`, `clearcache` (`Cleared local room cache.`), `backup`, `resetaard`,
`recon`/`recon?` (the norecall/noportal flagging from recon output — read the
reference trigger group).

## Phase 7 — Display-window & database commands → native equivalents
Keep the command names working, routed to our native map panel + Databases menu
(per the user decision), with a short note telling the user where it went:
`zoom in/out`, `hide`, `show`, `updown`, `underlines`, `compact`, `quicklist`,
`showroom` → map-panel controls; `database`, `set database`, `backups` → the
global `Databases/` model + Databases menu. (No miniwindow / multi-DB behaviour.)

## Phase 8 — Sectioned help
`mapper help [config|exits|portals|searching|exploring|moving|utils|all]` +
keyword search — port the reference `OnHelp()` text faithfully (it's what users
expect to read).

---

## Cross-cutting
- **Confirm-step pattern** (`purge … confirm`): a small stateful arm-then-execute
  on the `Mapper` actor (arm on first call, run on `… confirm`, time-bounded).
- **Ours-only commands** (`mapper depth`, `mapper blink`) have no reference
  equivalent — keep them (native map-panel features), documented as Proteles
  extensions, listed under `mapper help` separately so they don't masquerade as
  reference commands.
- **Tests:** per command, assert the exact reference output string(s) + that
  clickable rows carry the right `mapper goto <uid>`; table renderers get
  golden-output tests.
- **Live verification:** build + install per phase; the user spot-checks against
  MUSHclient. NO-GUESSING — read the reference per command before coding it.

## Suggested order of execution
Phase 0 (foundation) → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Each phase is its own
gated commit(s) + tests; Phase 0 must land first since every later phase emits
through it.
