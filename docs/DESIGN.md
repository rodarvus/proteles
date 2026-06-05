# Proteles — Design north-star

This is the **why** behind the UI: what Proteles should *feel* like, and the
principles every screen, control, and interaction is checked against. It is not a
backlog (that's GitHub Issues, label `ux`) and not architecture (that's
**PLAN.md**). When a design choice is contested, the answer should be derivable
from this doc — and if it isn't, we add the missing principle here.

**Status:** living draft, iterated from live use. Edit freely; contested calls
are marked **⚖︎** and collected under *Open questions*.

---

## 1. Who we're designing for

The **keyboard-first Aardwolf player**. Concretely:

- Plays for hours; the window is open all day. Long sessions mean **comfort and
  legibility beat novelty**.
- Lives at the keyboard. The mouse is a fallback, never the main path. A combat
  round is typed, not clicked.
- The screen during combat is a **glance-and-react HUD** — health, enemy, who's
  in the room — read in peripheral vision while typing the next command.
- Is a **power user**: aliases, triggers, timers, macros, scripts, and plugins
  are not advanced features bolted on — they're how this player *plays*. The MUD
  veteran arriving from MUSHclient/Mudlet expects that depth.
- Came to a **native Mac app on purpose** — they rejected Wine/VM/Electron. They
  expect Proteles to feel like Mail or Xcode, not a port. This is our edge; we
  spend it deliberately.

We are **not** designing for the first-time MUD player or the casual mouse-driven
user. We don't dumb the surface down for them; we make the powerful thing also
*discoverable* (see §3.5).

---

## 2. The three macOS pillars, our reading

Apple's HIG rests on **Clarity, Deference, Depth**. For a text-heavy MUD client:

- **Clarity** — the game text is the content; everything else is in service of
  reading and acting on it. Type sizes, contrast, and hierarchy make the
  important thing obvious at a glance.
- **Deference** — chrome gets out of the way of the output. Panels, bars, and
  controls frame the text; they never compete with it. Color and motion are used
  sparingly and on purpose, so the MUD's own color carries meaning.
- **Depth** — power is layered: the surface is calm, the depth (scripting,
  plugins, layout) is there when you reach for it, revealed through standard
  affordances (menus, inspectors, keyboard).

---

## 3. Principles

Ranked. When two conflict, the higher one wins.

### 3.1 The output is sacred
The game output view is the heart of the app. Therefore:
- **Never jank.** A combat burst, a `who`, a giant `map` must scroll at 60fps.
  Rendering perf is a UX feature, not an optimization. (TextKit 2; D-logged.)
- **Never lose text.** Scrollback is trustworthy; a reconnect, copyover, or panel
  re-dock doesn't truncate history. Scroll position is preserved when new text
  arrives while you're reading back.
- **The MUD owns its color.** We render Aardwolf's ANSI/`@`-color faithfully and
  do not recolor game text for our own UI purposes. Our chrome uses *our* palette;
  the output uses the *theme's* palette.
- **Readable by default.** The default theme + font + size must be comfortable for
  hours with zero configuration. Light themes get a contrast clamp so bright MUD
  text stays legible (already a decision).

### 3.2 Keyboard-first, mouse-optional
Every primary action has a key path; the mouse is never *required* to play.
- **The command input always has focus.** You can type a command immediately,
  even right after selecting/copying from the output, or clicking a panel. Focus
  returning to input is the default resting state. (Already a decision.)
- **Standard shortcuts mean standard things.** ⌘C copies, ⌘F finds, ⌘W closes,
  ↑/↓ recall history, Tab completes. We never repurpose a system-standard chord.
- **Discoverable shortcuts.** Every shortcut lives in the menu bar next to its
  command, so ⌘-hunting in menus teaches the keyboard. Macros the user defines
  show their chord wherever the action appears (button bar, etc.).
- **No dead ends.** If a thing can be done by mouse (re-dock a panel, pick a
  target), there should be a keyboard route too, or a clear reason there isn't.

### 3.3 Glanceable, not noisy
The HUD is read in the corner of the eye.
- **Encode status in position + color, not text to parse.** The vitals bars, the
  enemy gauge, the group panel's hurt/leader/align cues are shapes you read
  pre-attentively. Numbers are available but secondary (an option, not the
  default). (Already reflected in the status bar's number modes.)
- **Motion means something.** Animate to show a real state change (HP dropping,
  a quest going ready), never for decoration. Combat is busy enough.
- **Quiet when nothing's happening.** Idle, the app is calm: no spinners, no
  pulsing, no attention-grabs. Notifications are suppressed while focused by
  default.

### 3.4 One window, many panels — your arrangement, remembered
MUDs are information-dense, and power users stack plugin miniwindows. We **allow**
that, but the *default* is calm: **start with a single output panel**, and let the
user add more.
- **Calm default, extensible + customisable.** Out of the box: one resizable
  output window. Adding panels is an easy, obvious step — a comfortable target is
  **2–3 panels visible at once** without it feeling cramped.
- **A tiled dock first; floating is a deliberate, first-class capability** (not an
  afterthought). The user can **pop a panel (or a plugin miniwindow) out** of the
  dock and then choose to **anchor it to an edge** of their choosing *or* let it
  **float freely**. Pop-out → anchor/float must be obvious, reversible, and
  remembered. *(Today's floating-window implementation is weak and is a priority
  rework — see the `ux` backlog.)*
- **Plugin miniwindows are panels too.** A MUSHclient-style miniwindow becomes a
  native pop-out-able panel, dockable or floating like any other — not a
  pixel-copied overlay.
- **Layout is the user's, and it persists** per world. Presets + Reset Layout
  mean experimenting is safe.
- **Panels are glance surfaces, not apps.** A panel shows one thing well (map,
  group, channels, a plugin miniwindow). Deep interaction (editing scripts,
  managing plugins) belongs in a dedicated window, not crammed into a dock tile.

### 3.5 Power, made discoverable
Scripting/plugins are first-class, but the depth shouldn't be a cliff.
- **Progressive disclosure.** A new user sees a clean window; the power
  (Scripts ⇧⌘T, Plugins ⇧⌘P, layout) is one obvious step away, not in your face.
- **GUI and text agree.** A trigger made in the editor and one made by a plugin
  behave identically; a button fires through the same pipeline as typing the
  command. No "magic" paths the user can't reason about.
- **Plain language over jargon at the surface; precise terms in the depth.** The
  Plugin Library says "add a plugin from your Mac or a URL"; the script editor
  can say `omit_from_output` because by then you're in expert territory.
- **Honor the player's existing investment.** Import their MUSHclient map, S&D,
  dinv, leveldb databases; run their plugins. Migrating *to* Proteles should feel
  like coming home, not starting over.

### 3.6 Native, not approximate
We earn the "native Mac app" claim every screen.
- **Real AppKit/SwiftUI controls**, standard inspectors, standard sheets, the
  real menu bar, the standard Settings window, system colors that respect
  Increase Contrast / Reduce Motion / Dark Mode.
- **Behave like the OS:** window state restoration, sensible window min/ideal
  sizes, resizable everything, Services/Sharing where it fits, drag-and-drop that
  works the Mac way.
- **Don't import other platforms' conventions.** We reference MUSHclient/Mudlet
  for *protocol + behavior fidelity*, not for their Windows/Qt UI idioms. A
  MUSHclient miniwindow becomes a native panel, not a pixel-copy.

### 3.7 Trust & calm
- **Local-first, private.** Recordings, diagnostics, passwords (Keychain) stay on
  the machine; anything that could leave is opt-in and says so plainly.
- **Forgiving.** Destructive actions confirm or undo. The app reconnects on a
  drop. Config changes are reversible and say when they take effect ("on next
  connect").
- **Honest feedback.** When something's wrong (can't connect, a plugin failed),
  say so in plain language with a next step — never a silent failure (the #15
  "Add Group did nothing" bug is the anti-pattern we fix and don't repeat).

---

## 4. Surface-by-surface intent

A quick statement of what each surface is *for*, so reviews have a yardstick.

- **Output view** — read the game, comfortably, for hours. Select/copy with
  color. Click-throughs (exits, help links, URLs) are a bonus, never required.
- **Command input** — type fast, recall history, complete words, never lose
  focus. Assistive (ghost hint, completion) but never *alters* what you send.
- **Vitals bar** — peripheral-vision HUD of the six stats + combat enemy. Glance,
  don't read.
- **Map / Text Map** — "where am I, where can I go," at a glance; navigation is a
  command, the panel is the picture.
- **Character / Group / Channels** — situational awareness: who/what is here, what
  was said. Glance surfaces.
- **Scripts (⇧⌘T)** — author + manage triggers/aliases/timers/macros/buttons.
  A focused editor window, Mac-standard list+detail.
- **Plugins (⇧⌘P)** — a discoverable library: add, inspect, update, export. Plain
  language; the compatibility report sets expectations before installing.
- **Levels (⇧⌘L)** — analytics you read, not edit. Charts + sortable reports.
- **Settings (⌘,)** — find and change a preference fast. Tabbed, every control
  applies live or says when it takes effect.
- **Notifications** — pull attention *only* when you're away and it matters.

---

## 5. Typography, color, spacing

- **Output font:** monospaced, user-choosable, comfortable default size. Column
  alignment matters (MUD ASCII art, tables) — never substitute a proportional
  font in the output.
- **Chrome font:** the system font (SF). Panels, labels, settings use native text
  styles (`.body`, `.caption`) so Dynamic Type / accessibility sizes are honored.
- **Our palette is restrained** and theme-aware, distinct from the game's ANSI so
  the eye separates "app" from "game." Accent follows the system accent where it
  makes sense.

### 5.1 Theme fidelity (the default theme must match MUSHclient)
The **out-of-box default theme is the MUSHclient default** — the colors the
Aardwolf community already reads the game in. Faithfulness is a correctness
requirement, not a taste call:
- **Match the reference palette exactly.** Per the no-guessing rule, derive the
  16/256 ANSI values from the references
  (`aardwolfclientpackage/.../aardwolf_colors.lua`, MUSHclient's default world
  colors, iTerm2 for sanity) — don't eyeball them. Our current "Aardwolf" theme is
  *approximate*; several colors are off.
- **Dark colors must be readable on a black background.** Today the darker ANSI
  colors (e.g. dark blue/black-ish) are nearly invisible on black — a real
  legibility bug. The fix follows MUSHclient's actual rendering (and any minimum
  on-background contrast it applies), not an invented clamp. The **light** theme's
  contrast clamp already exists; the **default/dark** path needs the same care.
- Reviewing + fixing the reference-faithfulness of every shipped theme is `ux`
  backlog, with the MUSHclient-default theme as the priority.
- **Spacing is generous but not wasteful** — this is a dense app for a power user;
  we use standard macOS metrics, not cramped custom ones, but we don't pad a
  glance-HUD into needing a scroll.

---

## 6. Accessibility (not optional)

- Honor **Increase Contrast, Reduce Motion, Reduce Transparency, Dark Mode**, and
  Dynamic Type in the chrome.
- **VoiceOver:** controls are labeled; the output is navigable. (Tracked under the
  `accessibility` label.)
- **Full keyboard access:** see §3.2 — this overlaps heavily with our core
  audience's needs, so a11y and our north-star pull the same direction.
- Color is **never the only signal** (the align dot also has position/shape; HP
  has a number mode).

---

## 7. Anti-patterns (what we refuse to do)

- Janky/slow output rendering under load.
- Losing scrollback or scroll position.
- Recoloring or rewriting game text for our own UI.
- Mouse-only actions with no keyboard path.
- Non-standard meanings for standard shortcuts.
- Modal interruptions during play.
- Silent failures (a click that "does nothing").
- Decorative motion/color that competes with combat.
- Fixed-size or non-resizable windows that can trap the user (the #24 Settings
  collapse).
- Pixel-copying Windows/Qt UI instead of doing the Mac-native equivalent.

---

## 8. Resolved direction

The founding calls, settled (2026-06; folded into the principles above):

1. **Density:** calm, sane, *extensible* default. MUDs are dense and power users
   stack miniwindows — we allow that, but ship a comfortable single-panel start
   that's easy to extend + customise. (§3.4)
2. **Default theme = the MUSHclient default**, matched faithfully from the
   references. Current "Aardwolf" theme is approximate and has off / unreadable
   colors; fixing it is priority `ux` work. (§5.1)
3. **Panel/float model:** start with one panel; make 2–3 simultaneous panels an
   easy option; **pop-out from panels** (incl. plugin miniwindows) with
   **anchor-to-edge or free-float**. Today's floating-window story is weak and is
   a priority rework. (§3.4)
4. **Hand-holding:** sane defaults + discoverable UI, and *no more*. Assume
   competence; don't nanny. (§3.5)
5. **Stay Mac-pure.** No designing to a cross-platform lowest common denominator.
   If/when Proteles reaches iPad it gets its own approach — touch and the iPad's
   primitives differ enough that constraining the Mac app now would only dull it.
6. **Personality** *(clarified — this asked: should Proteles have a small visual
   identity, or look maximally like a stock system app?)*. Direction: **mostly
   system-native + neutral, with a light, consistent identity** — a coherent app
   icon, one restrained accent, consistent SF Symbol iconography, and the faithful
   theme. No skeuomorphism, no heavy branding, no decorative flourish. Revisit if
   it ever feels *too* anonymous.

## 9. First polish pass — the papercuts

The two biggest daily-play papercuts, which anchor the initial `ux` work:

- **A. The panel / floating-window story is still broken.** Pop-out, anchoring,
  and free-floating need a real rework to match §3.4. This is the top item.
- **B. Window polish is thin** across the secondary windows — **Scripts /
  Aliases / Commands (button bar) / Plugins / Settings**. Layout, spacing,
  hierarchy, empty states, and Mac-native feel all need a pass.

Each becomes one or more `ux` issues, reviewed against this doc.
