# Plan: output-buffer world API (gap-audit Tier 2, phase A)

Status: **proposed** — awaiting approval before implementation.

## Goal & why

Add MUSHclient's output-buffer introspection functions to the generic compat
shim:

- `GetLineCount()` — total lines received this session.
- `GetLinesInBufferCount()` — lines currently in the buffer.
- `GetLineInfo(lineNumber, infoType)` — a field of one buffered line.
- `GetStyleInfo(lineNumber, styleNumber, infoType)` — a field of one style run.
- `GetRecentLines(count)` — the last `count` lines' text, `\n`-joined.

This is the **Sath traceback thread**: Sath's `traceback_context.xml` dies on
`GetLineCount` (an unimplemented world API), and these functions are the
foundation for the planned native Lua-Console "traceback context" feature
(show the recent output lines around a script error). Per the gap audit
(`docs/MUSHCLIENT_LUA_GAP.md`), `GetLineInfo`/`GetLineCount`/
`GetLinesInBufferCount` are the Tier-2 buffer family.

`DeleteLines` is **deferred** — it mutates the display buffer, is rarely used,
and interacts with our TextKit render pipeline; out of scope for this phase.

## Reference semantics (MUSHclient, verified)

`GetLineInfo(LineNumber, InfoType)` (`methods_info.cpp:1177`): `LineNumber` is
**1-indexed buffer position** (1 = oldest line still in the buffer), validated
`1..GetLinesInBufferCount()`; out-of-range → empty; unknown `InfoType` → null.

| InfoType | returns | Proteles |
|---|---|---|
| 1 | text | ✅ `line.text` |
| 2 | length (UTF-8 **bytes**) | ✅ `line.text.utf8.count` |
| 3 | hard_return (newline) | ⚠️ stub `true` (we store whole lines) |
| 4 | note (COMMENT flag) | ✅ via pushed line-kind |
| 5 | user (USER_INPUT flag) | ✅ via pushed line-kind |
| 6 | log | ⚠️ stub `false` (no per-line log flag) |
| 7 | bookmark | ⚠️ stub `false` (no bookmarks) |
| 8 | hr (horizontal rule) | ⚠️ stub `false` |
| 9 | time | ✅ `line.timestamp` |
| 10 | line id (`m_nLineNumber`) | ✅ `line.id.raw` |
| 11 | style count | ✅ `line.runs.count` |
| 12 | high-res ticks | ⚠️ map to `monotonic`-style seconds |
| 13 | elapsed since connect | ✅ `timestamp − connectedAt` |

`GetStyleInfo(line, style, infoType)` (`methods_info.cpp:1270`): style
1-indexed; empty if out of range; null for unknown infotype.

| InfoType | returns | Proteles |
|---|---|---|
| 1 | run text | ✅ substring over the run |
| 2 | length (bytes) | ✅ run text UTF-8 byte count |
| 3 | start column (1-indexed, bytes) | ✅ byte offset + 1 |
| 4 | action type (0 none/1 send/2 link/3 prompt) | ✅ link → 1 or 2 |
| 5 | action (command/URL) | ✅ `run.link?.action` |
| 6 | hint | ✅ `run.link?.hint` |
| 7 | variable | ⚠️ stub `""` (no set-variable links) |
| 8–13 | bold/underline/blink/inverse/changed/start-tag | ✅ from `run.style` (changed/start-tag stub false) |
| 14 | fore colour (COLORREF) | ✅ `MUSHColour.int(for:)` of fg |
| 15 | back colour (COLORREF) | ✅ of bg |

`GetLineCount` = `m_total_lines` (running counter of all lines received);
`GetLinesInBufferCount` = `m_LineList.GetCount()` (current buffer size);
`GetRecentLines(count)` = last `count` buffer lines' stripped text, `\n`-joined.

## Proteles design

**Where the buffer lives.** These calls run synchronously inside the Lua
runtime, which cannot `await` the `ScrollbackStore` actor mid-call. So the
runtime keeps its own bounded mirror of the displayed lines — exactly the
pattern `GetInfo(280/281)` uses for live output geometry
(`outputPixelHeight/Width`, pushed via a method, read synchronously).

New `nonisolated(unsafe)` state on `LuaRuntime`:
- `outputLineBuffer: Deque<BufferedLine>` — bounded ring of recent displayed
  lines. `BufferedLine` = `{ id, timestamp, text, runs, kind }`.
- `totalLinesReceived: Int` — running counter (never decremented; no
  `DeleteLines` this phase), backing `GetLineCount`.
- `connectedAt: Date` — set on connect, for infotype 13.

**Capture point.** `SessionController.appendLineThroughScripts(_:)` already
takes each line to scripts + scrollback. After gag/omit resolution (so the
mirror matches the *displayed* buffer, as MUSHclient excludes omitted lines),
it calls `scriptEngine.recordOutputLine(line, kind:)`. `kind` is
`.mud` / `.note` / `.userInput`, known at the append site (MUD output vs a
script `note`/`echo` effect vs echoed input) → backs infotypes 4/5 faithfully.

**Ring bound.** Proposed **1000** lines (the consumer is "recent context", not
full history; our TextKit doc is separately bounded at 10k). Tunable; flagged
as a decision below.

**Dispatch.** Five value-returning host functions
(`proteles.lineCount` / `linesInBuffer` / `lineInfo` / `styleInfo` /
`recentLines`) routed through `queryValue` (a new `bufferValue` helper, like
`colourValue`), with thin generic-shim globals. Pure mapping logic
(infotype → value over a `BufferedLine`) lives in a testable value type so the
host layer is a thin adapter.

**Byte vs UTF-16 offsets.** MUSHclient is byte-oriented (`len`, style
start-column, style length are UTF-8 byte counts). Our `StyledRun` ranges are
UTF-16 code units. We convert to UTF-8 byte offsets at the boundary so a plugin
slicing text by these numbers gets MUSHclient-faithful results.

## Decisions to confirm before coding

1. **Ring bound = 1000?** (vs 5000 = MUSHclient's default `max_output_lines`).
   Memory is `~lines × (text + runs)`; 1000 is ample for traceback context.
2. **Push line-kind for note/user (infotypes 4/5)** — yes (cheap, faithful), or
   stub all provenance flags false for phase 1?
3. **`GetStyleInfo` scope** — implement now (it's the natural partner for
   reading coloured output), or defer to a phase A.2 and ship the count/text
   functions first?

## Test plan

- **Unit (pure):** seed a `BufferedLine` list; assert every `GetLineInfo`/
  `GetStyleInfo` infotype + bounds (n≤0, n>count → nil; unknown infotype → nil);
  byte-offset correctness on a multi-byte (UTF-8) line.
- **Shim:** `evaluateConsole` round-trips (`GetLineCount()` after N appends,
  `GetLineInfo(1, 1)` text, `GetStyleInfo` colour).
- **Live:** load a `GetLineCount`-based plugin (Sath-style) and confirm it runs;
  verify against a recording.

## Out of scope (later phases)

`DeleteLines` (buffer mutation); the native Lua-Console traceback *feature* that
consumes this API (separate plan); Tier-2 group B (timer/alias introspection).
