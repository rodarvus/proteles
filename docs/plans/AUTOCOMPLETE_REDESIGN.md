# Plan — Input autocomplete redesign

## Problem

The old input did **whole-line, history-only, word-blind** completion, presented
as an **aggressive inline auto-suggestion**: typing a prefix inserted the most
recent matching *past command* with the suffix pre-selected, and a bare **Enter
accepted it**. In a MUD (constant short commands) this fires stale full commands
and can't complete a target that's on screen now (`kill Gal…` → `Galadon`).

## References (they converge)

- **Mudlet** (`mudlet/src/TCommandLine.cpp`): two separate mechanisms —
  **Tab/Shift-Tab** completes the *current word* from the last ~500 lines of
  output (+ a settable suggestion list, minus a blacklist), cycling; **Up/Down**
  is whole-line history; **Enter just sends**.
- **iTerm2** (Cmd-;): autocomplete the current word from anything on screen.
- Best practice: complete the **current word** from **words seen on screen**, on
  an **explicit key**, **preserving the rest of the line**; history is a separate,
  non-intrusive Up/Down recall.

## Design (decided)

Three separated behaviours:

1. **Tab / Shift-Tab → word-level completion.** Completes only the current word
   (token ending at the caret); the rest of the line is preserved. **Cycle in
   place**: first Tab fills the best match, each further Tab swaps to the next,
   Shift-Tab goes back. Vocabulary, ranked:
   - **Context nouns (highest):** live GMCP — room `exits`, room players, group
     members, room-name words, channel names. *(Proteles advantage over Mudlet.)*
   - **Recent output words:** harvested from the last N scrollback lines,
     most-recent first.
   - **Command verbs / aliases:** only when completing the **first word**.
2. **Subtle ghost hint while typing.** A greyed, trailing suggestion (the best
   current-word completion) follows the caret. **→ or Tab accepts it; Enter
   ignores it and sends only what was typed.** Never auto-sent.
3. **Up/Down → history recall** (whole-line, cycled), applied only on the
   keypress — never while typing. **Enter sends exactly what's in the box.**

The dangerous inline-auto-accept is removed entirely.

## Architecture

- **MudCore (pure, tested):** `CompletionVocabulary` — holds context/recent/verb
  word lists and answers `completions(forWord:isFirstWord:)` (case-insensitive
  prefix, strictly longer, deduped, ranked). Word helpers: current-word span at a
  caret, first-word test, and a scrollback word harvester.
- **Session wiring:** the view is fed the three source lists — recent scrollback
  lines (`ScrollbackStore`), GMCP nouns (`RoomInfo`/`GroupInfo`/channels), and the
  verb/alias list — refreshed as they change.
- **MudUI (`CommandInputView`):** ghost-text rendering (grey trailing run in the
  field editor), Tab/Shift-Tab cycle, → / Tab accept, Enter sends typed-only,
  Up/Down history (unchanged), Esc dismisses the ghost.

## Status

**Shipped (v1):** the MudCore engine (`CompletionVocabulary` + `InputCompletion`,
18 tests) and the **Tab/Shift-Tab word-cycle** in `CommandInputView`, wired to a
live vocabulary in `ContentView` (recent output words via a `RecentLineBuffer`
fed by a `ScrollbackStore` subscription; GMCP room/group nouns; a verb set of
common commands + channel names). **Enter now sends exactly what's typed** — the
old auto-accept-on-Enter inline suggestion is gone (the core fix).

**Shipped (v2, #13 / D-96) — the as-you-type ghost hint.** A greyed,
*non-interactive* trailing hint of the best current-word completion, drawn after
the caret. **Approach:** rather than rewrite as a custom `NSTextView`, the ghost
is an **overlay label that's never part of the editable text** — a sibling view
in a small container, positioned at the field-editor caret rect
(`firstRect(forCharacterRange:)`). So it can't be sent, can't eat the spacebar,
and the Tab cycle / history / Enter-safety all stay exactly as they were. → or
Tab accepts (fills the same top match in its proper casing); Esc dismisses;
Enter sends only what's typed; any caret move/edit drops it (real typing
re-shows it). Gated by a "Suggest completions as you type" toggle (default on).
The suffix comes from a pure `CompletionVocabulary.ghostSuffix(forWord:isFirstWord:)`.

*Decision deferred (iterate):* whether the overlay proves robust enough
long-term or we move to a custom `NSTextView` — revisit if positioning/scroll
edge cases bite. *Deferred (v3):* a whole-line **history** ghost (fish-style) as
a second source; v2 is word-level only (predictable, matches Tab).
