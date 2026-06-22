# Generic MUSHclient Miniwindow Support — Feasibility & Level of Effort

> **Status (updated):** **SHIPPED.** The generic miniwindow API described below
> was subsequently built and merged — it is no longer an open feasibility
> question. Arbitrary third-party shim plugins that call `WindowCreate`/
> `WindowRectOp`/`WindowText`/hotspots/images render and are interactive through
> the generic runtime: the shim loads `miniWindowShimSource`
> (`LuaRuntime+CompatShim.swift`), host drawing lives in `LuaRuntime+MiniWindow*
> .swift`, and the UI mounts `MiniWindowOverlay`
> (`apps/ProtelesApp_macOS/Sources/ContentView.swift`). The exotic tail
> (blend/filter/transform image ops, window-enumeration queries, `WindowMenu`)
> remains stubbed, filled in per-plugin on demand. The sections below are the
> original feasibility analysis, kept for the design rationale.
>
> *(Original status:)* investigation / comparison artifact. Not scheduled, not a
> 1.0 goal. Produced on branch `experiment/miniwindow-support`, in parallel with
> `experiment/consider-miniwindow` (a native single-purpose window spike), to weigh
> a **generic miniwindow API** against the established **per-feature native panel**
> strategy.
>
> **Scope of this document:** running *unmodified* third-party MUSHclient plugins
> that draw miniwindows, through the generic `mush.lua` shim — and, where it comes
> for free, rendering them *nicer* than MUSHclient does. **Search-and-Destroy is
> explicitly out of scope**: it already runs on a dedicated native host with a
> native `SnDPanelView`, and is not a target consumer here.

## 1. Context — why this is being asked again

Proteles deliberately does **not** support miniwindows. The relevant decisions:

- **D-19 (2026-05-22):** "`proteles.*` as a rich primitive layer; native panels
  instead of a generic miniwindow drawing API" — *adopted*.
- **D-34 (2026-05-26):** the aardwolfclientpackage triage; 17 plugins dropped
  because "miniwindow infra collapses the dependency graph" — once the mapper,
  health, group, chat, statmon, and tick features are native, the miniwindow
  infrastructure plugins (`aard_repaint_buffer`, `aard_miniwindow_z_order_monitor`,
  `aard_layout`, `Time`, …) have nothing left to support.
- **D-45 (2026-05-27):** Rich Exits done as native clickable exits, "not a
  miniwindow port".

D-19 was the right call for the *first-party* feature set: every load-bearing
Aardwolf feature deserves a real Mac-native panel, not a generic floating canvas.
This document does **not** dispute that. It asks a narrower, orthogonal question
the native-panel strategy structurally cannot answer:

> **How hard would it be to run an arbitrary third-party MUSHclient plugin — one we
> will never port natively — that paints its own UI with `WindowCreate` &c.?**

That is the single capability native panels can never provide, and the only reason
to revisit miniwindows at all.

## 2. Bottom line

- **Feasible — and lower-risk than the API's surface area suggests.** Proteles
  already has every architectural primitive required. This is **not** "build a 2D
  graphics engine." It is: add one effect type that carries a retained draw-command
  scene, render that scene with SwiftUI `Canvas`, and route mouse gestures back to
  the plugin through the *existing* named-Lua-function call path. Phases 1–4 require
  **no invasive change** to the TextKit output view.
- **The realistic compatibility target is the shared miniwindow Lua libraries, not
  the raw 44–59-function API.** Real plugins almost never call `Window*` directly;
  they build on the Aardwolf package's `mw.lua`, `movewindow.lua`, `gauge.lua`,
  `scrollbar.lua`, `text_rect.lua`, and `themed_miniwindows.lua`. **If those
  libraries run, most third-party miniwindow plugins run.** That is a bounded,
  testable target.
- **"Most real plugins work" = Phases 0–4.** The exotic tail (Phase 5: 64 blend
  modes, 27 filters, affine transforms, pixel-exact metrics, draw-behind-text)
  should be built **on demand** when a specific imported plugin needs a specific
  feature — never budgeted as an upfront deliverable.
- **Rendering them *nicer* than MUSHclient is mostly free** — it falls out of using
  `Canvas` + the existing `FloatingMiniWindow` chrome, not extra engineering.

## 3. The compatibility target in detail

The reference Aardwolf plugins that use miniwindows (group monitor, health bars,
channels, bigmap, statmon, ASCII map, tick timer) are themselves **redundant** —
Proteles already ships native equivalents (D-25/33/36/38/40/80/95). But they are
the best available *corpus* for "what a real miniwindow plugin actually calls,"
because they exercise the shared libraries the same way third-party plugins do.

Supporting the libraries' real footprint is the goal:

| Shared library | Role | Proteles phase that covers it |
|---|---|---|
| `movewindow.lua` | drag-to-move + position persistence | Phase 1 (`WindowPosition`) + Phase 2 (`WindowDragHandler`) |
| `mw.lua` / `mw_theme_base.lua` | themed frames, title bars, buttons | Phases 1 & 4 (`WindowRectOp`, gradients, small images) |
| `gauge.lua` | HP/MP/XP-style bars | Phase 1 (`WindowRectOp` + `WindowText`) |
| `text_rect.lua` | scrollable text regions | Phases 1–2 (`WindowText`, hotspots, scrollwheel) |
| `scrollbar.lua` | scrollbars on text regions | Phase 2 (hotspots + drag) |
| `themed_miniwindows.lua` | resizable/closable framed windows | Phases 1–2; reuse `FloatingMiniWindow` chrome |

**Observed `Window*` frequency** across the reference plugins (the functions worth
optimizing for): `WindowRectOp`, `WindowText`, `WindowCreate`/`WindowDelete`,
`WindowFont`, `WindowPosition`/`WindowResize`/`WindowShow`,
`WindowAddHotspot`/`WindowDeleteHotspot`, `WindowLine`, `WindowDrawImageAlpha`,
`WindowInfo`/`WindowHotspotInfo`, `WindowCircleOp`. The long tail —
`WindowFilter`, `WindowBlendImage`, `WindowMergeImageAlpha`, `WindowTransformImage`,
`WindowBezier`, `WindowArc`, `WindowPolygon` — is rarely touched.

## 4. How miniwindows work in MUSHclient (the model to emulate)

Authoritative source: `submodules/mushclient/scripting/methods/methods_miniwindows.cpp`
(API), `submodules/mushclient/miniwindow.{h,cpp}` (implementation), and
`submodules/mushclient/mushview.cpp` (redraw).

- A miniwindow is an **offscreen pixel buffer** (top-left origin, logical pixels)
  with a registry of named fonts, named images, and named hotspots.
- Drawing functions (`WindowText`, `WindowRectOp`, `WindowLine`, `WindowCircleOp`,
  …) mutate that buffer. They do **not** repaint the screen.
- The client repaints by calling each plugin's **`OnPluginDrawOutputWindow`**
  callback once per output redraw, then blits each window's buffer over (or under,
  with `create_underneath`) the text. (`mushview.cpp:1056` dispatches the callback;
  the blit loops are at `mushview.cpp:996–1006` and `1498–1506`.)
- **Hotspots** carry up to five **Lua function-name strings** (`MouseOver`,
  `CancelMouseOver`, `MouseDown`, `CancelMouseDown`, `MouseUp`) plus optional drag
  and scroll-wheel handlers. When the mouse interacts with a hotspot rect, the
  client calls the named global function with `(flags, hotspot_id)`.
- ~14 position constants (`pos_top_left` … `pos_center_all`, `pos_tile`) and create
  flags (`create_underneath`, `create_absolute_location`, `create_transparent`,
  `create_ignore_mouse`, `create_keep_hotspots`).

## 5. Recommended architecture (if a spike follows)

### 5.1 Core model — a retained command-list scene rendered by SwiftUI `Canvas`

**Not** an imperative AppKit `NSView`/`CALayer` that plugins draw into. This is the
load-bearing decision, and it is forced by Proteles' own rules:

- The scripting architecture is "**Lua decides and records inert,
  `Sendable`/`Equatable` effect *values*; the actor applies them later.**" An
  imperative surface would require Lua's `WindowRectOp`, called from the
  `nonisolated` Lua executor, to reach a **live main-actor `CGContext`** — a direct
  Swift 6 strict-concurrency boundary violation.
- A retained `[DrawCommand]` value list crosses the actor boundary cleanly, exactly
  as `Line` / `ScriptStyleRun` already do.
- `Canvas` is declarative and GPU-backed: re-yielding a scene re-renders with no
  manual invalidation, and the per-frame cost of replaying tens-to-low-hundreds of
  primitives is trivial — the Map panel already does equivalent work each redraw
  (`Sources/MudUI/Map/MapPanelView+Drawing.swift`).

### 5.2 Three existing seams reused verbatim

1. **`publish → AsyncStream → @Observable → SwiftUI`.** The exact path the S&D
   native panel uses: `publishedModels: AsyncStream<String>`
   (`Sources/MudCore/Session/SessionController.swift:83`), yielded at
   `Sources/MudCore/Session/SessionController+Scripting.swift:228`. Add a sibling
   `miniWindowScenes` stream + an `@Observable MiniWindowStore`.
2. **`Canvas` / `GraphicsContext` drawing.** `MapPanelView+Drawing.swift` already
   renders arcs, polygons, gradients, and hatching by hand. The new
   `MiniWindowCanvasView` replays the command list the same way.
3. **Floating window chrome.** `Sources/MudUI/Layout/FloatingMiniWindow.swift`
   (`FloatingMiniWindow` + `FloatingPanelLayer`, with drag/dock/close/resize/
   snap-to-corner) and `Sources/MudUI/Layout/LayoutStore.swift` already exist. Host
   miniwindows in the `FloatingPanelLayer` ZStack over the output — **zero new
   compositing infrastructure for Phases 1–4.**

### 5.3 Host functions live on the generic shim runtime

Third-party plugins run through the generic `mush.lua` shim (S&D has its own
dedicated runtime, which is out of scope). The `Window*` host functions register on
the shim runtime. **Gotcha:** the shim is multiple Lua chunks and `local`s do not
cross chunks — host functions must be globals/`proteles.*`, not chunk-locals.

### 5.4 "Per-frame redraw" maps to "re-publish on state change"

Proteles has no per-frame plugin-draw hook and should **not** synthesize a 60 fps
tick (it would fight `@Observable` and waste cycles). Instead:

- Accumulate a plugin's `Window*` calls into a **per-window scratch command buffer**
  (the `nonisolated(unsafe)` pattern already used for the `effects` array in
  `LuaRuntime`), and emit **one** `.updateMiniWindow(scene)` effect when the draw
  pass commits.
- The draw pass is driven by the events the plugin already reacts to — a GMCP
  update, a trigger match, a timer — which is exactly when `@Observable` wants to
  re-render anyway. This is the same "re-publish on state change" shape every native
  panel already uses.
- **Nuance:** the shim must still expose a `Redraw()` / `OnPluginDrawOutputWindow`
  entry point so plugins that drive their own repaint schedule (e.g. a sweeping
  clock hand on a `doAfter` timer) get called. The existing timer engine supports
  this; no global frame loop is needed.

### 5.5 Hotspot / mouse-event routing (UI → actor → named Lua function)

The callbacks are string function names. When a `Canvas` gesture lands on a hotspot
rect, we must invoke that named global in the originating plugin's runtime. This
mechanism **already exists** and only needs generalizing:

- `SearchAndDestroyHost.call(function:args:)` already invokes a named global Lua
  function across the actor boundary (`runtime.run("if type(fn)=='function' then
  fn(...) end")` — `SearchAndDestroyHost.swift:192`).
- Flow: `Canvas` gesture → resolve top-of-z-order hotspot under the point → build a
  `MiniWindowEvent { windowId, hotspotId, kind, x, y, flags }` → `await
  session.dispatchMiniWindowEvent(event)` → resolve the owning plugin's runtime →
  call the named callback with `(flags, hotspotId)`. Returned effects flow back
  through the normal `applyScriptEffects` path.
- One actor hop each way — identical to every typed command. Debounce
  `MouseOver`/`CancelMouseOver` to hotspot **entry/exit** transitions UI-side to
  avoid flooding the actor with per-pixel moves.

## 6. Phased plan & level of effort

Each phase is independently shippable and adds a capability tier.

| Phase | Covers (`Window*`) | New work | LOE |
|---|---|---|---|
| **0 — Scaffolding** | — | `MiniWindowScene` / `DrawCommand` value types; `.updateMiniWindow` / `.deleteMiniWindow` effect cases; unit tests on the scene reducer (no UI, no Lua) | **Small** |
| **1 — MVP** | Create, Delete, Show, Resize, Position, RectOp (fill/frame), Text, Line, SetPixel, Font, **TextWidth** | ~10 shim host fns; per-window draw accumulation + commit semantics; `MiniWindowCanvasView` + `MiniWindowStore` + `miniWindowScenes` stream | **Large** |
| **2 — Hotspots** | AddHotspot, DeleteHotspot, MoveHotspot, HotspotInfo, DragHandler, ScrollwheelHandler | `MiniWindowEvent`; `dispatchMiniWindowEvent`; hit-testing + z-order; generalized named-function dispatch | **Medium** |
| **3 — Images** | LoadImage, LoadImageMemory, DrawImage, DrawImageAlpha, ImageInfo | image store keyed by `(pluginId, imageId)` → `CGImage`; bytes stay out of the effect value (keyed by id) | **Medium** |
| **4 — Shapes & tail** | CircleOp, Gradient, Polygon, Arc, Bezier, RectOp 3D/rounded, FontInfo | mechanical `Path` / `GraphicsContext` replay cases | **Small–Medium** |
| **5 — Fidelity tail** | BlendImage, MergeImageAlpha, Filter (27 ops / 64 modes), `create_underneath`, `create_transparent`, pixel-exact metrics | CoreImage `CIFilter` passes; behind-text compositing; CoreText width matching | **X-Large — build on demand** |

**"Most real third-party plugins work" = Phases 0–4** (Small + Large + Medium +
Medium + Small-Medium). The biggest single chunk of novel design is Phase 1's
accumulation/commit semantics (one effect per *draw pass*, not per primitive) plus
the synchronous `WindowTextWidth` query path. Phase 5 is an open-ended parity tax —
scope it to the specific plugin in front of you, not to the spec.

### Key file touch points (for a future spike)

- `Sources/MudCore/Scripting/ScriptTypes.swift` — new effect cases (the value
  contract).
- `Sources/MudCore/Scripting/LuaRuntime.swift` +
  `Sources/MudCore/Scripting/LuaRuntime+HostFunction.swift` — register the `Window*`
  host fns **in the shim**; the per-window accumulation buffer; the **synchronous**
  `WindowTextWidth` / `WindowFontInfo` query path (Lua reads the return value
  inline); generalize the named-function invocation borrowed from `SearchAndDestroyHost`.
- `Sources/MudCore/Session/SessionController.swift` + a new
  `Sources/MudCore/Session/SessionController+MiniWindow.swift` (respect the 600-line
  budget) — apply the new effects; the `miniWindowScenes` stream;
  `dispatchMiniWindowEvent(_:)`.
- New `Sources/MudCore/Scripting/MiniWindow*.swift` — the scene/command value types.
- New `Sources/MudUI/.../MiniWindowCanvasView.swift` + `MiniWindowStore` — render,
  modeled on `MapPanelView+Drawing.swift`, hosted in `FloatingPanelLayer`.

## 7. Making miniwindows *nicer* than MUSHclient (mostly free)

The upside of re-rendering through native primitives rather than blitting a GDI
buffer:

- **Crisp Retina text** via CoreText, vs. MUSHclient's 1× GDI bitmap glyphs.
- **Native window chrome** — `FloatingMiniWindow` already provides smooth dragging,
  snap-to-corner, resize grips, and translucency the 20-year-old GDI canvas lacks.
- **Antialiased shapes** by default (`Canvas` AA; MUSHclient shapes are aliased).
- **Optional vibrancy / rounded corners** on the host frame.

**Restraint required.** Plugins position every draw by absolute pixel and lay text
out from `WindowTextWidth` returns. "Nicer" must mean better *rendering of the same
geometry* (AA, subpixel text, native chrome) — **not** re-flowing or re-laying-out
content, which would break the plugin's own coordinate math.

## 8. Hardest parts & risks

- **Pixel-exact font metrics.** Plugins position subsequent draws at the pixel
  offset returned by `WindowTextWidth`; even 1 px of drift misaligns multi-call
  layouts. Mitigation: answer the query via CoreText
  (`CTLineGetTypographicBounds`) on the *exact* resolved `NSFont` the `Canvas` will
  draw with. Accept small drift in Phase 1; tighten in Phase 5.
- **Shared-library coverage cascades.** A single missing `WindowInfo` field that a
  library reads can break a whole class of plugins (the libs assume the full query
  surface). Mitigation: test against `mw.lua` / `movewindow.lua` early, not just
  isolated `Window*` calls.
- **Mouse-move callback flood.** `MouseOver` fires continuously; debounce to
  entry/exit transitions UI-side.
- **`create_underneath` (draw behind text).** The only case the ZStack-sibling
  approach cannot satisfy — the `NSTextView` background is opaque
  (`Sources/MudOutputView_macOS/MudOutputView.swift:195`). Deferred to Phase 5;
  requires a transparent text background and placing the under-text Canvas behind
  the text in the ZStack. Rare in practice.
- **Blend modes (64) / filters (27).** Map the common modes to `CGBlendMode` /
  CoreImage; log-and-approximate the exotic ones. Almost no real plugin exercises
  the full matrix.
- **Per-frame animation.** Event-driven repaint means a plugin animating without a
  timer would not animate. Most use timers (supported); document the gap.

## 9. Recommendation

- **For the first-party feature set, D-19 stands** — native panels remain the right
  choice for mapper/chat/group/health/etc.
- **Generic miniwindow support is a separable, additive capability** aimed solely at
  *unmodified third-party plugins*. It is feasible at **Medium-to-Large** effort for
  the part that matters (Phases 0–4), reuses Proteles' existing seams rather than
  fighting them, and can render results nicer than MUSHclient for free.
- **Recommended posture:** treat it as **opt-in, on-demand, post-1.0**. If pursued,
  build the **Phase 0–1 spike first** to validate the accumulation/commit model and
  font-metric fidelity against `mw.lua` + `movewindow.lua`, then decide whether the
  third-party-plugin demand justifies Phases 2–4. Do not pre-build Phase 5.

## 10. Verification approach (for a spike)

- **Phase 0:** unit-test the scene reducer in MudCore (pure value types, no UI/Lua)
  — the "engines decide, are unit-testable" rule.
- **Phase 1:** a minimal test Lua plugin on the shim calling `WindowCreate` +
  `WindowRectOp` + `WindowText`; build → install to `~/Applications` → clear
  quarantine → launch and confirm the floating panel renders; confirm the binary
  contains the new symbols (`nm | grep`).
- **End-to-end ground truth:** drive a real reference plugin that uses
  `mw.lua`/`movewindow.lua` through the shim and compare its window against a
  MUSHclient screenshot — verify against the reference, not a passing isolated test.
- All four gates green: `swift build`, `swift test --parallel`,
  `swiftformat --lint .`, `swiftlint --strict`.

---

*References: MUSHclient source under `submodules/mushclient/` (miniwindow API +
view redraw); reference plugins and shared libs under
`submodules/aardwolfclientpackage/MUSHclient/{lua,worlds/plugins}/`; Proteles seams
cited inline. Prior decisions: D-19, D-34, D-45 in `docs/DECISIONS.md`.*
