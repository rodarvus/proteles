# Platform API headroom — what the deployment floors hold back

A reference snapshot, taken **2026-09-16** while assessing the move to
**macOS 27 / Xcode 27.0 / Swift 6.4** (macOS 27 was installed on the dev machine
on 2026-09-03). It answers two questions that come up whenever the floors are
discussed:

1. Which platform APIs would Proteles plausibly use, but cannot at the current
   deployment floor without an availability branch?
2. Which APIs are *already* available at the floor and simply unused?

Floors at the time of writing: **macOS 15** (D-103) and **iOS 26** (D-125,
raised from 18 the same day this document was written, because no iOS UI code
exists yet). Follow-up tracking lives in GitHub Issues, not here — see #90 for
the SwiftUI adoption work.

## Method

- Apple's per-release change lists: the *SwiftUI updates* and *AppKit updates*
  pages (June 2024 = macOS 15 / iOS 18, June 2025 = macOS 26 / iOS 26,
  June 2026 = macOS 27 / iOS 27), the Xcode 27 release notes, and the Swift 6.4
  release post.
- The macOS 27 SDK's `.swiftinterface` files, for availability annotations where
  the release lists were ambiguous. Note Swift 6.4's `anyAppleOS` availability
  token (`@available(anyAppleOS 26.0, *)`) — a grep for `@available(macOS` alone
  misses it.
- A survey of what the codebase uses today (counts are files): `.toolbar` 9,
  `Table(` 5, `NavigationSplitView` 4, `.searchable` 3, materials 8,
  `@Observable` 22, `TextEditor` 1, panel drag-and-drop 1, `WKWebView` 0.

Availability was confirmed for the items marked ✓; the rest are placed by the
release they were announced in.

## Held back by the macOS 15 floor

### macOS 26 (June 2025)

| API | Proteles surface | Notes |
|---|---|---|
| `TextEditor` bound to `AttributedString`; `AttributedTextSelection`; `FindContext`; `AttributedTextFormattingDefinition` | The one `TextEditor`; any future rich-text editing | The command input is on `NSTextView` by design (#71) and is not a candidate |
| `WebView` / `WebPage` (SwiftUI-native WebKit) | None today | No `WKWebView` exists; noted only so nobody adds a representable when this becomes usable |
| Liquid Glass: `glassEffect(_:in:)`, `GlassEffectContainer`, `PrimitiveButtonStyle.glass`, `ToolbarSpacer` ✓, `scrollEdgeEffectStyle`, `backgroundExtensionEffect`; AppKit `NSGlassEffectView`, `NSBackgroundExtensionView`, `NSButton.BezelStyle.glass`, `NSView.prefersCompactControlSizeMetrics` (opt-out of the new control metrics) | The 8 files using materials; chrome, HUD, toolbars | Purely visual. Whether Proteles adopts the macOS 26 look is a `docs/DESIGN.md` question, not an availability one |
| `windowResizeAnchor(_:)` ✓ | Detached panel windows | Cosmetic |
| `@Animatable` macro | Map panel animations | Convenience |
| `draggable(containerItemID:containerNamespace:)` / `dragContainer` | Panel layout drag-and-drop | Multi-item drag; superseded for our case by the macOS 27 reordering API below |
| `NSSplitViewItem` top/bottom accessory view controllers | Chrome around the output split | If the AppKit split container ever hosts accessories |
| `NSToolbarItem.Style.prominent` + `backgroundTintColor` | Toolbars | Cosmetic |
| `NSHostingSceneRepresentation`, `NSGestureRecognizerRepresentable` | SwiftUI ↔ AppKit seams | Convenience for the miniwindow hotspot layer |
| Runtime: `Observations` (async sequence over `@Observable` changes) ✓, `Task.immediate` ✓ | The 22 `@Observable` models feeding the HUD | `Observations` is the notable one: a first-party stream of model changes instead of polling or hand-rolled publishers |
| Foundation Models (on-device LLM) | See the parked section below | macOS 26+, Apple Intelligence hardware |
| Pasteboard privacy: `NSPasteboard.detect…`, `accessBehavior` | Command input paste, miniwindow copy | Prepares for the macOS alert on programmatic pasteboard reads; worth a look before it lands regardless of floor |

### macOS 27 (June 2026)

| API | Proteles surface | Notes |
|---|---|---|
| `DynamicViewContent.reorderable()` + `View.reorderContainer(for:isEnabled:move:)` | Panel layout (`PanelDragDrop`, `PanelLayoutView`) | First-party reordering across stacks/grids/custom layouts; the strongest single candidate. #90 |
| `ToolbarContent.visibilityPriority(_:)` ✓, `ToolbarOverflowMenu`, `ToolbarItemPlacement.topBarPinnedTrailing`, `toolbarMinimizeBehavior` | The 9 toolbars | Deterministic overflow when a window narrows. #90 |
| `swipeActions(…)` / `swipeActionsContainer()` outside `List` | Chat rows, plugin rows | #90 |
| `alert(error:actions:)`, `alert(_:item:actions:)`, `confirmationDialog(_:item:…)` | Import sheet, plugin install errors | Present straight from an `Error`. #90 |
| `NavigationTransition.crossFade` | Sheets | Cosmetic |
| Gesture input kinds (`GestureInputKinds`) | Map panel | Limit a gesture to pointer vs touch |
| `NSMenuItem.preferredImageVisibility` | Panel "Float" / "Open in Window" menu | **Behaviour change**: macOS 27 hides SF Symbol images in `NSMenu` by default when built against the 27 SDK. Needed only to restore the icons |
| `NSTextSelectionManager` (gesture-recogniser text selection in `NSTextView`), `NSRefreshController`, `NSControl.Events`, `NSView.beginDraggingSession(items:gesture:source:)` | `MudTextView` (an `NSTextView` subclass) | No action: the view overrides no mouse methods, so it is already on the new path. Only `TailResizeHandle` (a plain `NSView`) overrides `mouseDown`/`mouseDragged`/`mouseUp`, which is unaffected |
| Runtime: `withTaskCancellationShield` ✓ (`anyAppleOS 27`) | `SessionController` teardown | Cleanup that must complete after cancellation |
| SwiftUI `Text` selection + `TextRenderer` on `Text` | — | **Not a candidate.** The output view stays on TextKit 2; a 10k-line scrollback with per-line accessibility elements is not what these are for |
| Document API (`ReadableDocument` / `WritableDocument`) | — | Proteles is not document-based |

### Free with an Xcode 27 build (no OS gate)

- `@State` is now a macro: a class-typed `@State` is initialised **once**, not on
  every body evaluation. Worth auditing our `@State` properties that hold
  reference types.
- `ContentBuilder` unifies `ToolbarContentBuilder` / `CommandsBuilder`.
- Swift 6.4 language features (compile-time, any OS): `async` in `defer`
  (SE-0493), `weak let`, `~Sendable` (SE-0518), `@diagnose` (SE-0522),
  `anyAppleOS` availability, module selectors `A::B` (SE-0491), optional
  `some`/`any` without parentheses (SE-0521), Swift Testing ↔ XCTest assertion
  interop. `withTaskCancellationShield` is the exception: it needs the OS 27
  runtime.

## Held back by the iOS floor (now 26)

With the floor at 26, the iOS 26 additions above (gesture-based text
interactions, `TextEditor` on `AttributedString`, `Observations`,
`Task.immediate`, Liquid Glass) are usable unconditionally when the iOS UI
phases start. Still gated to iOS 27: `reorderable()`, `visibilityPriority`,
`swipeActionsContainer`, `TabRole.prominent`, and UIKit's iPhone Mirroring
layouts. The output view direction is unchanged by any of this: UIKit +
CoreText after SwiftTerm (`docs/plans/IOS_PORT_PLAN.md`), not SwiftUI `Text`.

## Available at the current floors and unused

| API | Available since | Where it would help |
|---|---|---|
| `textInputSuggestions(_:)` / `textInputCompletion(_:)` | macOS 15 ✓ | Command completion (#31 / #32) on any SwiftUI text field |
| `WindowDragGesture` | macOS 15 ✓ | Extra drag regions on detached panel windows |
| `UtilityWindow` + `WindowVisibilityToggle` | macOS 15 ✓ | Floating tool windows (Lua console, diagnostics) |
| `pointerStyle(_:)`, `pointerVisibility` | macOS 15 ✓ | Map panel, resize handles |
| `onModifierKeysChanged(mask:initial:_:)`, `modifierKeyAlternate` | macOS 15 ✓ | Modifier-aware toolbar/menu alternates |
| `onScrollGeometryChange`, `onScrollPhaseChange`, `ScrollPosition` | macOS 15 | Chat panel viewport tracking (currently AppKit-anchored by hand) |
| `TabViewStyle.sidebarAdaptable`, `TabSection`, `tabViewCustomization` | macOS 15 | Scripts window tabs |
| `presentationSizing(_:)` (`.form`, `.page`) | macOS 15 | Sheets |
| `NSTextField.suggestionsDelegate` | macOS 15 | AppKit-side completion popover |
| `NSHostingMenu` | macOS 15 | Share menu definitions between SwiftUI and the AppKit main menu |
| `NSAnimationContext.animate(_:changes:completion:)` | macOS 15 | SwiftUI animations on AppKit views |
| `Mutex` (Synchronization), `Atomic` | macOS 15 | Already usable wherever an actor is too heavy |
| `@Entry` macro, `@Previewable`, `PreviewModifier` | any (Xcode 16) | Environment keys and previews |
| `MeshGradient`, `Color.mix`, symbol effects (`wiggle`, `rotate`, `breathe`) | macOS 15 | HUD polish |

## Parked: Foundation Models

Assessed and deliberately **not pursued now** (2026-09-16). Kept here so the
assessment does not have to be redone.

- **What it is.** Apple's on-device language model behind Apple Intelligence
  (roughly 3B parameters, a few-thousand-token context, English plus a short
  language list), exposed via `SystemLanguageModel`, `LanguageModelSession`,
  `@Generable` schema-guaranteed output, and the `Tool` protocol. macOS 26+,
  Apple silicon with Apple Intelligence enabled. Availability must be checked at
  runtime: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`,
  `unsupportedLanguageOrLocale`.
- **macOS 27 additions.** `PrivateCloudComputeLanguageModel` (larger context,
  quota API, an entitlement); multimodal `Attachment` prompts; the
  `LanguageModel` / `LanguageModelExecutor` protocols so a session can run
  against any provider, including a Core AI export or a hosted model; dynamic
  profiles that swap instructions and tools at runtime.
- **Plausible fits, in order.** (1) A trigger/alias authoring assistant that
  turns a pasted game line plus a description into a reviewable regex and
  action — the one place where the no-guessing rule and a model coexist well,
  because the output is inspected before it runs. (2) "What did I miss":
  summarise channel chatter or a recording segment. (3) Plain-language
  explanation of a Lua traceback beside the existing source-context view.
  (4) Question answering over the bundled help articles.
- **Non-fits.** Anything per line. Inference is tens to hundreds of
  milliseconds, so it can never sit in the classifier, the semantic event layer,
  or the render path. Also macOS 26 only, so at a macOS 15 floor it would have to
  be optional and self-hiding.

## Keeping this current

Re-run the three-step method above when a floor changes or a new major OS
ships; update the tables rather than appending. Anything that becomes actual
work gets a GitHub Issue, not a line here.
