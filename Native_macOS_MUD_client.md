*Query:*

I am considering the idea of developing a native macOS MUD client. The two most versatile MUD clients are MUSHCLient, a native Windows application, and mudlet, a multi-platform client written in Qt. I'm thinking of a native Swift application. What are your thoughts on libraries and frameworks I should use? particularly for high-performance text output, and utility and networking libraries? I have programming experience in general, but limited experience with Swift and macOS development. Development is likely almost exclusively going to happen within Claude Code, but it would be nice to use an IDE. I want to explore my options there as well.

*Claude answer:*

Building a native macOS MUD client in Swift is a fun project, and there's a real gap there — the existing macOS options (Atlantis, Savitar, etc.) are mostly stale, and Mudlet on macOS feels distinctly non-native. A few thoughts, organized by the areas you asked about.

**The hard part: text output**

This is where most MUD clients live or die. Aardwolf and similar muds can fire dozens of lines per second during combat or movement, and users expect tens of thousands of lines of scrollback with instant search and selection. Naive approaches collapse quickly.

Your two reasonable paths on macOS:

The native path is `NSTextView` with TextKit 2 enabled (TextKit 2 is the rewrite Apple introduced in macOS 12 — viewport-based layout, much better for large documents than TextKit 1). You'd back it with a custom `NSTextStorage` subclass that holds your scrollback efficiently and only materializes attributed runs for the visible viewport. iTerm2 has lived on heavily customized NSTextView for years, so it's viable, but the customization burden is real. For ANSI/SGR styling, you build attributed strings as you parse — `AttributedString` (Swift) or `NSAttributedString` (Cocoa) both work; you'll mostly use NSAttributedString since that's what NSTextView wants.

The custom path is rolling your own view: `NSScrollView` containing a custom `NSView` that uses Core Text directly to lay out and draw runs. More work upfront but you control everything — line wrapping policy, the scrollback data structure, how you batch redraws when text streams in. Terminal emulators like Alacritty/Ghostty go even further with GPU rendering, but for a MUD that's almost certainly overkill.

I'd start with TextKit 2 / NSTextView and only fall back to custom Core Text if profiling shows it can't keep up. Wrap whichever you choose in `NSViewRepresentable` so the rest of your UI can be SwiftUI.

**Networking**

Use **Network.framework** (`NWConnection`). It's Apple's modern TCP/TLS stack, integrates cleanly with Swift concurrency (`async`/`await`), and handles TLS without effort — useful since secure MUD connections (TLS on alternate ports) are increasingly common. It's the right level of abstraction for telnet: you're not fighting URLSession's request/response model, and you're not down at BSD sockets.

**SwiftNIO** is the alternative — Apple's high-performance async networking framework, with channel handlers, codecs, etc. It's overkill for a single connection and adds conceptual weight, but its `NIOExtras` package does include things like `LineBasedFrameDecoder` and there's prior art for telnet-shaped protocols. I'd default to Network.framework unless you find you want NIO's pipeline model.

For MUD-specific protocol layers you'll be writing yourself — there are no Swift libraries for these as far as I know, and I'd be surprised if there were:
- Telnet option negotiation (IAC/DO/DONT/WILL/WONT, subnegotiation)
- MCCP2/MCCP3 — zlib decompression on the inbound stream. Apple's `Compression` framework is one-shot oriented; for streaming inflate you'll likely want to call into libz directly via a small Swift wrapper, or use SwiftNIO's compression handlers.
- GMCP (JSON payloads — `JSONDecoder` handles this trivially), MSDP, MSSP, MXP if you want it, MTTS for terminal type negotiation.

**Utility libraries worth pulling in**

- `swift-collections` — specifically `Deque` is exactly what you want for a ring-buffer-style scrollback. `OrderedDictionary` is occasionally handy.
- `swift-algorithms` — windowing, chunking, etc. Nice to have.
- `swift-log` — standard logging facade.
- For configuration files, JSON via `Codable` covers most needs; if you want something more human-friendly, `Yams` for YAML.

**Scripting**

Worth thinking about early because it shapes the architecture. MUSHclient and Mudlet both expose Lua, and that's the de facto MUD scripting language — your users (if any) will expect it. Options:

- Embed Lua via C interop. Plain `lua` is a small library and Swift can call it directly. There's also `LuaSwift` and similar wrappers, though I'd verify current maintenance status before depending on one.
- Use `JavaScriptCore` (built into macOS). JS is a non-traditional choice for MUDs but no extra dependency and good Swift bridging.

If you want the script ecosystem effect (people sharing triggers, plugins, etc.), Lua is the answer. If you just want extensibility for yourself, JavaScriptCore is the path of least resistance.

**Architecture pattern**

SwiftUI for the chrome — preferences, connection manager, sidebar, tabs — and AppKit (`NSViewRepresentable`-wrapped) for the main output view and probably the input field. This hybrid is well-trodden and lets you use SwiftUI where it shines without fighting it for the streaming-text use case where it doesn't.

**IDE / build setup for a Claude Code workflow**

The pairing I'd suggest: Xcode for the things only Xcode does well (Instruments profiling, Interface Builder if you ever need it, asset catalogs, signing/notarization, SwiftUI previews) and **VS Code with the official Swift extension** (Apple maintains it now, uses sourcekit-lsp) as your everyday editor alongside Claude Code. Claude Code's terminal-native model meshes naturally with VS Code's terminal, and you get LSP features (jump-to-def, completion, diagnostics) without the heavyweight Xcode UI.

Cursor and Zed both work as VS Code-style alternatives with Swift LSP support if you prefer either of those. AppCode would have been ideal but JetBrains discontinued it.

For project structure: do as much as you can in Swift Package Manager (`Package.swift`), and only break out to an Xcode project for the actual app bundle target. Or use **XcodeGen** or **Tuist** to generate the `.xcodeproj` from a spec file — much friendlier with version control and Claude Code than hand-editing pbxproj. XcodeGen is the simpler of the two.

You can build and run from the command line with `xcodebuild` and `swift build`, which keeps Claude Code firmly in the loop. The main thing you'll occasionally pop into Xcode for is profiling with Instruments — and you'll want to, because text rendering performance is exactly the kind of thing where intuition fails and a profiler tells the truth.

One last thing worth flagging: I'd verify the current state of TextKit 2's performance characteristics with a small spike before committing — the framework has matured but there have been historical complaints about edge cases. A quick prototype that streams 100 lines/sec into an NSTextView with 50k lines of scrollback will tell you within a day whether the native path is viable for your needs.