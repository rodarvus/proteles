import Foundation

/// Native port of Fiendish's `aard_inventory_serials`: when enabled, typing
/// `inventory` (or an abbreviation) shows item **serial numbers** + flag colours
/// + grouped counts instead of the plain list. Independent reimplementation; the
/// pure parse/group/render lives in ``InventorySerials``.
///
/// Mechanism (no miniwindow): intercept the `inventory` command, send `invdata`
/// instead (the machine-readable form Aardwolf wraps in `{invdata}…{/invdata}`),
/// capture + gag that block, then re-emit the grouped list. Being a
/// `NativePlugin` gives it the per-world enabled flag + Plugins-window toggle —
/// disabling it restores the plain `inventory`. v1 covers the main inventory;
/// keyring/vault + a serial-colour command are a fast follow.
public struct InventorySerialsPlugin: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.inventoryserials",
        name: "Inventory Serials",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Show item serial numbers, flags, and counts in your inventory. "
            + "Disable to restore the plain list (persists per world)."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "When enabled, `inventory` (and its abbreviations) lists your items "
                + "grouped, with flag colours, counts, and serial numbers — by capturing "
                + "Aardwolf's `invdata` and re-rendering it. Disable to see the plain list."
        )
    }

    /// `inventory` + abbreviations (the reference's alias set).
    private static let inventoryCommands: Set<String> = [
        "i", "in", "inv", "inve", "inven", "invent", "invento", "inventor", "inventory"
    ]

    /// True while buffering rows between `{invdata}` and `{/invdata}`.
    private var capturing = false
    private var buffer: [String] = []

    public init() {}

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let command = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.inventoryCommands.contains(command) else { return nil }
        // Consume the typed command (already echoed by the send path) and ask
        // for the machine-readable form; the `{invdata}` block is captured below.
        capturing = true
        buffer = []
        return [.sendNoEcho("invdata")]
    }

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        guard capturing else { return .init() }
        let text = line.text
        if isOpenTag(text) {
            buffer = []
            return .init(gag: true) // swallow the {invdata} marker
        }
        if text == "{/invdata}" {
            capturing = false
            let rendered = InventorySerials.render(rows: buffer)
            buffer = []
            var effects: [ScriptEffect] = [.echoAard("@wYou are carrying:")]
            effects.append(contentsOf: rendered.map { .echoAard($0) })
            return .init(gag: true, effects: effects)
        }
        // Between the tags: buffer the data rows, gagged from the main window.
        buffer.append(text)
        return .init(gag: true)
    }

    /// `{invdata}` or `{invdata <containerId>}` (the open marker; a closing tag
    /// starts with `{/`).
    private func isOpenTag(_ text: String) -> Bool {
        text.hasPrefix("{invdata") && text.hasSuffix("}") && !text.hasPrefix("{/")
    }
}
