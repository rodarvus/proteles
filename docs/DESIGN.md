# Proteles — Design north-star

This is the **why** behind the UI: what Proteles should *feel* like, and the
principles every screen, control, and interaction is checked against. It is not a
backlog (that's GitHub Issues, label `ux`) and not architecture (that's
**[ARCHITECTURE.md](../ARCHITECTURE.md)**). When a design choice is contested, the answer should be derivable
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

### 3.4 Windows and panels — your arrangement, remembered

#### Vocabulary (we use these terms precisely)
- **Main window** - the single primary window: the output, the docked panels, the
  command input, and the vitals bar.
- **Panel** - a content surface (Output, Map, Text Map, Channels, Commands, S&D,
  Character/Group, plus plugin miniwindows). A panel has a *placement*:
  - **Docked** - tiled inside the main window's dock (split/tabbed).
  - **Floating miniwindow** - lifted out as a small, borderless, content-hugging
    overlay that hugs its content, anchors to a corner/edge, and can stack against
    other miniwindows. This is the "Text Map" style. *(Shipped for every panel via
    `FloatingPlacement` + `FloatingPanelLayer` — drag, edge-snap, resize, and
    per-world persistence; GitHub #33.)*
  - **Detached window** - the panel in its own standard titled window, for
    multi-monitor. This is the "Help-window-looking" style; useful, but it is NOT
    what most pop-outs should default to.
- **The dock** - the tiled, splittable region of the main window holding docked
  panels. It can hold panels side by side (left/right) or stacked, via splits.
- **Feature window** - a standalone top-level window that is *not* a panel:
  Help, Levels, Plugins, Scripts, Worlds, Settings. Full standard chrome,
  app-managed, opened from menus. (These are "apps within the app.")
- **Plugin miniwindow** - a MUSHclient-style plugin surface, treated as a panel
  (dockable or floating), never a pixel-copied overlay.

#### Principles
- **Calm default, extensible.** Out of the box: one main window with a single
  Output panel. Adding panels is an easy, obvious step; 2-3 visible panels should
  feel comfortable, not cramped.
- **Multiple docked panels by placement, not configuration.** The dock already
  supports splits; the user should be able to put one panel on the left and one
  on the right, or two on the right, just by **moving a panel** to that edge. The
  default is one; arranging more is a drag, not a settings dialog.
- **Floating miniwindows are first-class and economical.** A pop-out defaults to a
  *floating miniwindow* (the Text Map style), not a chrome-heavy detached window.
  It is **sized to what it needs** - dynamically computed minimum, not fixed:
  Commands asks for only enough to show its buttons; Channels wants as much as it
  can get. Each miniwindow **stores its required width/height** and is economical.
- **Anchoring + stacking.** Miniwindows **anchor to any corner**, and can anchor
  **relative to each other** (above / below / left / right) so they **auto-stack**
  cleanly instead of overlapping. Anchors are obvious, reversible, remembered.
- **Z-order that behaves.** A floating miniwindow stays above the *main window*
  while Proteles is active, but does **not** sit above *other apps* when Proteles
  is in the background.
- **No drag artifacts.** Re-docking/moving panels does not leave stray drop-zone
  rectangles ("the blue box") behind - the drag affordance appears and clears
  cleanly.
- **Layout is the user's, and it persists** per world. Presets + Reset Layout make
  experimenting safe.
- **Panels are glance surfaces, not apps.** A panel shows one thing well. Deep
  interaction (editing scripts, managing plugins) belongs in a *feature window*,
  not crammed into a dock tile.

*The windowing rework above shipped (GitHub #33): `FloatingPlacement` +
`FloatingPanelLayer` give every panel borderless floating with drag, edge-snap,
resize, and per-world persistence; plugin miniwindows are first-class panels; the
blue-box and z-order bugs are resolved. Residual surface-by-surface polish
surfaces as new `ux` issues as it's found.*

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
- **Honor the player's existing investment.** *(Realized in `v0.6.0`.)*
  **File ▸ Import from MUSHclient…** brings a whole install over — connection +
  autologin, aliases/triggers/timers/macros/keypad, their third-party plugins, and
  the map/S&D/dinv/leveldb databases. Migrating *to* Proteles should feel like
  coming home, not starting over.

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
- **Match the reference palette exactly.** Per the no-guessing rule, the 16/256
  ANSI values are derived from the references
  (`submodules/aardwolfclientpackage/.../aardwolf_colors.lua`, MUSHclient's default
  world colors, iTerm2 for sanity) — not eyeballed. The ANSI-16 palette matches the
  community default; the main window matches the Channels window and MUSHclient
  (GitHub #34, D-99).
- **Dark colors are readable on a black background.** The original legibility bug
  was that **bold ANSI** (`\e[1;3Xm`) rendered as the dim *normal* color instead of
  bright (so bold-black was invisible, bold-blue dark navy). The fix follows
  MUSHclient's `<bold>` palette: `resolveForeground(_:bold:)` upgrades bold →
  bright across all four render surfaces, and the darkest xterm codes are remapped
  per Aardwolf's `x_not_too_dark`. The **light** theme keeps its contrast clamp.
- Reviewing the reference-faithfulness of *additional* shipped themes is ongoing
  `ux` polish; the MUSHclient-default theme — the one that matters — is done.
- **Spacing is generous but not wasteful** — this is a dense app for a power user;
  we use standard macOS metrics, not cramped custom ones, but we don't pad a
  glance-HUD into needing a scroll.

---

## 6. Accessibility (not optional)

- Honor **Increase Contrast, Reduce Motion, Reduce Transparency, Dark Mode**,
  and Dynamic Type in the chrome.
- **Text-to-speech shipped** (D-110): game lines, tells, and alerts are spoken
  via an app voice or routed to VoiceOver (`announcementRequested`), configured
  in Settings ▸ Audio. The speech decision pipeline is unit-tested end-to-end.
- **VoiceOver:** native VO output is the first accessibility milestone. Every
  displayed game line should reach VoiceOver in display order, queue behind any
  line already being spoken, and keep VO focus on the command input so the
  player can keep typing. The planned work is a reliable VO output path, a
  deliberate output-review mode with text selection/link navigation, semantic
  review buffers for high-value streams such as tells/channels/URLs/command
  output, an AX-labeling + `performAccessibilityAudit` pass (the automatable
  half of #26), and **validation with a real visually-impaired player** (the
  human half, #9).
  Color is **never the only signal** (the align dot also has position/shape; HP
  has a number mode), which already serves low-vision users.
- **Server-assisted settings are secondary:** Aardwolf already provides
  `blindmode`, structured `tags`, `spamreduce`, `brief`, and tell replay.
  Proteles may expose an explicit, reversible opt-in helper for those settings,
  but it must not treat `blindmode` as the primary accessibility mechanism or
  make its public/private privacy choice for the user.
- **Full keyboard access:** see §3.2 — this overlaps heavily with our core
  audience's needs, so a11y and our north-star pull the same direction.

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
   references. *Done* — the bold→bright fix (D-99) and palette matching landed in
   v0.4.8; the default theme matches MUSHclient. (§5.1, #34)
3. **Panel/float model:** start with one panel; make 2–3 simultaneous panels an
   easy option; **pop-out from panels** (incl. plugin miniwindows) with
   **anchor-to-edge or free-float**. *Done* — the floating-miniwindow rework
   shipped (`FloatingPlacement`/`FloatingPanelLayer`). (§3.4, #33)
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

## 9. First polish pass — delivered

The two biggest daily-play papercuts that anchored the initial `ux` work have
both shipped:

- **A. The panel / floating-window story.** *Done (#33).* Pop-out, anchoring,
  free-floating, edge-snap, resize, and per-world persistence landed via
  `FloatingPlacement`/`FloatingPanelLayer`, matching §3.4.
- **B. Window polish across the secondary windows.** *Done (#35).* The
  Scripts / Commands (button bar) / Plugins windows, the Settings reshape (seven
  scoped tabs), and the menu-bar pass all landed.

The `ux` backlog is currently clear; new polish items get their own `ux` issue,
reviewed against this doc. With these and the audio/accessibility work (§6)
shipped, Proteles is **feature-complete for 1.0**; remaining design work is
incremental polish, not a gate.
