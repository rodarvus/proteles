import Foundation

/// Native completion of Aardwolf's `aard_GMCP_handler` (Fiendish).
///
/// Most of that plugin's job is **already native** in Proteles and must not be
/// duplicated: the wire layer performs GMCP telnet negotiation (`WILL`→`DO`,
/// `Core.Hello`, `Core.Supports.Set`), `GMCPMessage.aardwolfHandshake` sends
/// the initial `config`/`request` batch (the plugin's `fetch_all()`), incoming
/// packets are decoded into `proteles.gmcp`, and the GMCP→`OnPluginBroadcast`
/// bridge already impersonates this plugin's id (`3e7dedbe37e44942dd46d264`).
///
/// This plugin fills the two pieces that were *not* yet native:
///
/// 1. **The `sendgmcp <payload>` command** — the `sendgmcp *` alias that turns
///    e.g. `sendgmcp config prompt` into a real GMCP packet
///    (`Send_GMCP_Packet("config prompt")`). Without it the text hits the MUD
///    as an unknown command. Other plugins reach it via `Execute("sendgmcp …")`.
/// 2. **Config-state synthesis** — Aardwolf emits no `config` GMCP when the
///    user toggles prompt/compact via the normal commands, so the reference
///    plugin watches the text feedback and synthesizes the GMCP itself
///    (`OnPluginTelnetSubnegotiation(201, 'config { … }')`). We do the same via
///    the `injectGMCP` effect, keeping downstream config state accurate.
///
/// Deliberately *not* ported (Windows/MUSHclient-only or obsolete here): the
/// `OnPluginTelnetRequest` registry/`luacom` ident block, the `gmcpdebug`
/// toggle, `OnPluginListChanged`→`aard_requirements`, and `getmemoryusage`.
public struct AardGMCPHandler: NativePlugin {
    public let metadata = NativePluginMetadata(
        id: "com.proteles.gmcphandler",
        name: "Aardwolf GMCP Handler",
        author: "Proteles (after Fiendish)",
        version: "1.0",
        summary: "Adds the `sendgmcp` command and synthesizes config GMCP from "
            + "prompt/compact toggles (the rest of the handler is native already)."
    )

    public var help: NativePluginHelp {
        NativePluginHelp(
            overview: "Completes Aardwolf's GMCP handler natively. GMCP negotiation, "
                + "decode, the initial request batch, and plugin broadcasts are already "
                + "built in; this adds the `sendgmcp` command and keeps prompt/compact "
                + "config state in sync when you toggle them by command.",
            commands: [
                .init(
                    syntax: "sendgmcp <payload>",
                    summary: "Send <payload> to the server as a GMCP packet, "
                        + "e.g. `sendgmcp config prompt` or `sendgmcp request quest`."
                )
            ]
        )
    }

    public init() {}

    // MARK: - Command (`sendgmcp *`)

    public func handleCommand(_ input: String) -> [ScriptEffect]? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        // MUSHclient alias `sendgmcp *`: the verb plus a non-empty payload.
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sendgmcp" else { return nil }
        // Preserve payload casing — GMCP package names are case-sensitive
        // (e.g. `Core.Hello`, `Char.Items`).
        let payload = parts[1].trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return nil }
        return [.sendGMCP(payload)]
    }

    // MARK: - Config-state synthesis

    public func onLine(_ line: Line) -> ScriptEngine.LineDisposition {
        guard let effect = Self.configSynthesis(for: line.text.trimmingCharacters(in: .whitespaces))
        else { return .init() }
        // The reference triggers don't omit the line, so it stays visible.
        return .init(effects: [effect])
    }

    /// Map Aardwolf's prompt/compact toggle feedback to a synthesized `config`
    /// GMCP, mirroring aard_GMCP_handler's two triggers exactly.
    static func configSynthesis(for text: String) -> ScriptEffect? {
        switch text {
        case "You will now see prompts.":
            .injectGMCP(package: "config", json: #"{"prompt":"YES"}"#)
        case "You will no longer see prompts.":
            .injectGMCP(package: "config", json: #"{"prompt":"NO"}"#)
        case "Compact mode set.":
            .injectGMCP(package: "config", json: #"{"compact":"YES"}"#)
        case "Compact mode removed.":
            .injectGMCP(package: "config", json: #"{"compact":"NO"}"#)
        default:
            nil
        }
    }
}
