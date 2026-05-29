import Foundation

/// Native port of Fiendish's `aard_inventory_serials`: when enabled, `inventory`
/// (and abbreviations), `keyring list`, and `vault list` show item **serial
/// numbers** + flag colours + grouped counts instead of the plain list.
/// Independent reimplementation; the pure parse/group/render lives in
/// ``InventorySerials``.
///
/// Mechanism (no miniwindow): intercept the list command, send the
/// machine-readable form (`invdata` / `keyring data` / `vault data`) Aardwolf
/// wraps in `{invdata}…{/invdata}` (resp. `{keyring}` / `{vault}`), capture +
/// gag that block, then re-emit the grouped list. Being a `NativePlugin` gives
/// it the per-world enabled flag + Plugins-window toggle; the serial colour is
/// set with `inventory serials color <@code>` and persisted per world.
public struct InventorySerialsPlugin: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.inventoryserials",
        name: "Inventory Serials",
        author: "Proteles (after Fiendish)",
        version: "1.1",
        summary: "Show item serial numbers, flags, and counts for inventory, keyring, "
            + "and vault. Disable to restore the plain lists (persists per world)."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "When enabled, `inventory` (and its abbreviations), `keyring list`, and "
                + "`vault list` show your items grouped, with flag colours, counts, and serial "
                + "numbers — by capturing Aardwolf's data form and re-rendering it. "
                + "`inventory serials color <@code>` sets the serial colour; disable the plugin "
                + "to see the plain lists."
        )
    }

    /// Which list we're capturing — picks the close tag + header + data command.
    private enum Source: Equatable {
        case inventory, keyring, vault

        var dataCommand: String {
            switch self {
            case .inventory: "invdata"
            case .keyring: "keyring data"
            case .vault: "vault data"
            }
        }

        /// The open marker prefix (`{invdata` also accepts `{invdata <id>}`).
        var openPrefix: String {
            switch self {
            case .inventory: "{invdata"
            case .keyring: "{keyring"
            case .vault: "{vault"
            }
        }

        var closeTag: String {
            switch self {
            case .inventory: "{/invdata}"
            case .keyring: "{/keyring}"
            case .vault: "{/vault}"
            }
        }

        var header: String {
            switch self {
            case .inventory: "@wYou are carrying:"
            case .keyring: "@C** Items on Keyring **@w"
            case .vault: "@C** Vault **@w"
            }
        }
    }

    /// `inventory` + abbreviations (the reference's alias set).
    private static let inventoryCommands: Set<String> = [
        "i", "in", "inv", "inve", "inven", "invent", "invento", "inventor", "inventory"
    ]

    /// Persisted per-world settings (just the serial colour for now).
    private struct State: Codable {
        var serialColour: String
    }

    /// Aardwolf `@`-colour for the serial brackets + name suffix. Configurable
    /// via `inventory serials color <@code>`; persisted.
    private var serialColour = "@w"

    /// The list currently being captured (nil = not capturing).
    private var capturing: Source?
    private var buffer: [String] = []

    public init() {}

    public mutating func handleCommand(_ input: String) -> [ScriptEffect]? {
        let command = input.trimmingCharacters(in: .whitespaces)
        let lower = command.lowercased()

        // Config sub-commands: `inventory serials color <@code>` / `… help`.
        if lower.hasPrefix("inventory serials") {
            return handleConfig(command)
        }

        let source: Source? = if Self.inventoryCommands.contains(lower) {
            .inventory
        } else if lower == "keyring list" {
            .keyring
        } else if lower == "vault list" {
            .vault
        } else {
            nil
        }
        guard let source else { return nil }
        // Consume the typed command (already echoed) and ask for the data form;
        // the tagged block is captured + re-rendered in onLine.
        capturing = source
        buffer = []
        return [.sendNoEcho(source.dataCommand)]
    }

    /// `inventory serials color <@code>` (set + persist the serial colour) and
    /// `inventory serials help`.
    private mutating func handleConfig(_ command: String) -> [ScriptEffect] {
        let rest = command.dropFirst("inventory serials".count).trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix("color") || rest.lowercased().hasPrefix("colour") {
            let code = rest.drop { !$0.isWhitespace }.trimmingCharacters(in: .whitespaces)
            guard !code.isEmpty else {
                return [.echoAard("Usage: inventory serials color <@code>  (e.g. @R for red)")]
            }
            serialColour = code
            return [
                .persistPluginState(id: metadata.id),
                .echoAard("\(serialColour)Serial colour set.@w")
            ]
        }
        return [.echoAard(
            "@wInventory Serials: type @Cinventory@w / @Ckeyring list@w / @Cvault list@w for "
                + "serialled lists; @Cinventory serials color <@code>@w sets the serial colour."
        )]
    }

    public mutating func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        guard let source = capturing else { return .init() }
        let text = line.text
        if text.hasPrefix(source.openPrefix), text.hasSuffix("}"), !text.hasPrefix("{/") {
            buffer = []
            return .init(gag: true) // swallow the open marker
        }
        if text == source.closeTag {
            capturing = nil
            let rendered = InventorySerials.render(rows: buffer, serialsColour: serialColour)
            buffer = []
            var effects: [ScriptEffect] = [.echoAard(source.header)]
            effects.append(contentsOf: rendered.map { .echoAard($0) })
            return .init(gag: true, effects: effects)
        }
        // Between the tags: buffer the data rows (count markers etc. that aren't
        // CSV rows are buffered too but dropped by the parser), gagged.
        buffer.append(text)
        return .init(gag: true)
    }

    public var persistentState: Data? {
        try? JSONEncoder().encode(State(serialColour: serialColour))
    }

    public mutating func restore(from data: Data) {
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        serialColour = state.serialColour
    }
}
