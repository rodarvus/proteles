import Foundation

/// Native port of Aardwolf's `Aardwolf_Tick_Timer` (Fiendish): a countdown to
/// the next game tick (the ~30s cycle — regen, etc.), shown in the status bar.
///
/// The reference sniffs the legacy telnet option 101 to anchor a fixed-30s
/// countdown; we use the modern `comm.tick` GMCP broadcast instead (one per
/// tick). On each `comm.tick` this emits an ``ScriptEffect/updateTick(_:)``
/// effect that re-anchors `GMCPState.lastTick`; `StatusBarView` renders the
/// live "Next tick: N" off that anchor (fixed 30s, unclamped — matching the
/// reference exactly; see ``GMCPState/secondsToNextTick``).
///
/// Being a `NativePlugin` (rather than a bare HUD feature) is deliberate: it
/// gets a per-world **enabled flag** persisted by `NativePluginStore` and a
/// toggle in the Plugins window — the faithful analog of disabling the plugin
/// in MUSHclient's Plugins dialog. When disabled, the host stops routing
/// `comm.tick` to it, ticks stop arriving, and the readout self-hides once the
/// anchor goes stale (`StatusBarView`).
public struct TickTimer: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.ticktimer",
        name: "Tick Timer",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Show a countdown to the next Aardwolf tick in the status bar. "
            + "Disable to hide it (persists per world)."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Counts down ~30s to the next game tick in the status bar, "
                + "anchored on the comm.tick GMCP broadcast. Disable in this window to "
                + "hide the readout; the choice is saved per world."
        )
    }

    public init() {}

    public mutating func onGMCP(package: String, json _: String) -> [ScriptEffect] {
        // Each comm.tick is one game tick; re-anchor the countdown to now.
        package.lowercased() == "comm.tick" ? [.updateTick(Date())] : []
    }
}
