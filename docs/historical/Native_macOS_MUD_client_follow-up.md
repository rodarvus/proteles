> **Historical.** The follow-up to the conversation that led me to start
> thinking about writing Proteles — here, on whether one codebase could serve
> both macOS and iOS. Kept for the record; not current design guidance. See
> [ARCHITECTURE.md](../../ARCHITECTURE.md) for the project as it stands.

---

*Query:*

Following-up on the thread above - would it be possible to use the same code base for macOS and iOS?

*Claude Answer:*

Yes, and Swift/Apple's ecosystem is actually quite well-suited for this — better than most cross-platform stacks. But the answer comes with real caveats specific to a MUD client.

**What shares cleanly**

The vast majority of your code can be shared: networking (Network.framework is identical on both), telnet/MCCP/GMCP parsing, ANSI parsing, scrollback data structures, trigger/alias/timer engines, scripting integration (Lua and JavaScriptCore both work on iOS), `Codable` configuration, logging. This is the bulk of a MUD client by line count. Structure it as a Swift package — call it something like `MudCore` — and link it into both app targets.

SwiftUI also largely shares: preferences screens, connection manager UI, sidebar/list views. You'll have platform conditionals (`#if os(macOS)` / `#if os(iOS)`) for menus, keyboard shortcuts, window management, and the input affordances, but the bones are the same.

**What doesn't share: the text view**

This is the catch, and it's a real one. The path I suggested — `NSTextView` with TextKit 2 wrapped in `NSViewRepresentable` — doesn't exist on iOS. iOS has `UITextView` (also TextKit 2-capable) wrapped in `UIViewRepresentable`. The APIs are *similar* but not identical: different class hierarchy, different gesture model, different selection UI, different keyboard handling, different scroll view integration.

In practice you write two thin platform-specific view layers that both consume the same underlying scrollback/storage model. Something like:

- `MudCore` (shared): scrollback storage, `NSAttributedString` building from parsed ANSI, line management
- `MudOutputView_macOS`: NSTextView-backed, NSViewRepresentable
- `MudOutputView_iOS`: UITextView-backed, UIViewRepresentable
- A protocol or shared SwiftUI wrapper that picks the right one

`NSAttributedString` itself is cross-platform (Foundation), as are the attribute keys for font, color, etc. — though `NSColor` vs `UIColor` and `NSFont` vs `UIFont` need a typealias dance. People usually define a `PlatformColor` typealias and bridge once.

If you go the custom Core Text path instead, Core Text is fully cross-platform — same API on both — so the rendering core ports directly. You'd still need separate gesture/selection/scroll wrappers, but the actual drawing code is shared. This is one argument for the custom path if iOS is a priority.

**Input field**

Similar story. macOS has `NSTextField`/`NSTextView`-as-input; iOS has `UITextField`/`UITextView` plus a software keyboard with its own behaviors (input accessory views for command history buttons, etc.). MUD command input on iOS specifically benefits from a custom toolbar above the keyboard — quick-access macro buttons are pretty much essential since typing `kill mob` repeatedly on a touch keyboard is miserable.

**The UX is genuinely different**

This is the part worth thinking about before you write code. A desktop MUD client and a mobile MUD client are not just the same app at different sizes:

- *Keyboard.* Desktop MUDders live on numpad macros, function keys, and chorded shortcuts. iOS has none of that natively. You either build elaborate on-screen macro panels (Mudlet's iOS approach, basically) or accept that mobile is for casual play. Hardware keyboard support on iPad helps but isn't universal.
- *Scrollback interaction.* Selecting text to copy a tell, scrolling back through combat — these are mouse/trackpad-native interactions. Touch works but needs different affordances.
- *Window management.* Desktop clients often have multiple panels (chat, map, inventory). iOS gets you one screen at a time, maybe split view on iPad. Your information architecture has to differ.
- *Background behavior.* iOS will suspend your app and kill the socket. You need to handle reconnection gracefully, possibly with push-based "you got a tell" notifications via a relay, which is a whole separate backend project. Desktop users just leave the client running.
- *iPad vs iPhone.* iPad can plausibly host the full experience, especially with a keyboard. iPhone is fundamentally a different product.

**Practical recommendation**

If iOS support is a goal, design for it from day one even if you ship macOS first. Concretely: put everything non-UI in a Swift package right away, use `PlatformColor`/`PlatformFont` typealiases from the start, and don't let AppKit types leak into your core. Retrofitting this later is painful; doing it upfront costs almost nothing.

But I'd encourage being clear-eyed about whether you want iOS to be a *first-class* client or a *companion* client. First-class — full triggers, scripting, multi-window-equivalent on iPad — is a substantially larger project, maybe 1.5–2× the work of macOS alone, with the mobile UX questions being the hard part rather than the code sharing. Companion — read-only or light-play, view your character, send a few commands, get notifications — is much smaller and arguably more useful given how mobile MUDding actually tends to work.

Mudlet's mobile situation is instructive: they shipped iOS and Android versions, and the consensus seems to be that they're functional but nobody's primary client. That's not a code-sharing failure; it's that mobile MUDding is genuinely harder UX than desktop, and "same codebase" doesn't solve it.

So: yes, very feasible, and Swift makes it cleaner than most alternatives would. Just don't let "shared codebase" become the goal in itself — it's a means to shipping a good iOS client, and the iOS client needs its own design thinking regardless.