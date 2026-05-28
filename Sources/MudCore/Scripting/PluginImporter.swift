import Foundation

/// A compatibility report for a MUSHclient plugin being imported: what the
/// plugin uses and how well Proteles supports it (PLAN.md §7.5). Produced by
/// ``PluginImporter/analyze(_:)`` and shown to the user during the guided
/// import so they see, before installing, what will work and what won't.
public struct PluginImportReport: Sendable, Equatable {
    public enum Severity: Sendable, Equatable, Comparable {
        case ok, warning, error
    }

    /// Overall outcome, derived from the worst finding.
    public enum Verdict: Sendable, Equatable {
        /// Everything the plugin uses is supported.
        case supported
        /// Works, but with limitations (partial APIs / unbundled libs).
        case worksWithCaveats
        /// Uses features Proteles doesn't support (miniwindows, COM, …);
        /// likely won't work fully.
        case unsupported
    }

    public struct Finding: Sendable, Equatable {
        public let severity: Severity
        public let message: String

        public init(severity: Severity, message: String) {
            self.severity = severity
            self.message = message
        }
    }

    public var name: String
    public var id: String
    public var author: String
    public var version: String
    public var triggerCount: Int
    public var aliasCount: Int
    public var timerCount: Int
    public var findings: [Finding]

    public var verdict: Verdict {
        switch findings.map(\.severity).max() {
        case .error: .unsupported
        case .warning: .worksWithCaveats
        default: .supported
        }
    }
}

/// Analyses a parsed MUSHclient plugin against Proteles' supported surface.
///
/// Heuristic, by design: it scans the plugin's `<script>` for world-API
/// method names and `require`s — the same signal the corpus research used —
/// and classifies each. It can't *run* the plugin, so it reports likely
/// compatibility, not a guarantee.
public enum PluginImporter {
    /// World-API methods the shim fully supports (real implementations, not
    /// stubs). Covers output/comms, variables/identity, the GMCP bridge,
    /// runtime + declarative automations and their group/name toggles, deferred
    /// actions, clickable links, plugin reload, and module loading — i.e. the
    /// surface the dinv/Search-and-Destroy work hardened.
    private static let supported: Set<String> = [
        // Output + comms
        "Send", "SendNoEcho", "Execute", "Note", "Tell", "AnsiNote",
        "ColourNote", "ColourTell", "print",
        // Variables / identity / GMCP
        "GetVariable", "SetVariable", "DeleteVariable", "GetPluginVariable",
        "GetPluginID", "GetPluginInfo", "BroadcastPlugin", "IsConnected",
        "Send_GMCP_Packet", "Trim", "CallPlugin",
        // Automations (runtime + group/name toggles — wired to the host engines)
        "AddTriggerEx", "AddTrigger", "AddAlias", "DeleteTrigger",
        "EnableTrigger", "EnableTimer", "EnableGroup", "EnableAlias",
        "EnableTriggerGroup", "EnableTimerGroup",
        // Deferred / lifecycle / links
        "DoAfter", "DoAfterSpecial", "ReloadPlugin", "Hyperlink", "MakeHyperlink",
        // Modules
        "require", "dofile", "loadstring"
    ]

    /// Methods that work but with a limitation a player might actually notice —
    /// phrased in plain language (no internal jargon).
    private static let partial: [String: String] = [
        "AddTimer": "a repeating timer created in script fires only once "
            + "(declarative `<timers>` and one-off waits/`DoAfter` work normally)"
    ]

    /// Methods that genuinely can't run, so the player should know — plain
    /// language, no jargon.
    private static let unsupported: [String: String] = [
        "luacom": "uses Windows-only automation (COM) that can't run on macOS"
    ]

    /// Helper libraries Proteles bundles for `require`.
    private static let bundledLibraries: Set<String> = [
        "gmcphelper", "serialize", "json", "aardwolf_colors",
        "tprint", "copytable", "commas", "pairsbykeys", "wait", "check"
    ]

    /// Libraries we register as inert stubs so `require` succeeds, but whose
    /// real (network/background) behaviour isn't provided.
    private static let stubbedLibraries: Set<String> = ["async"]

    public static func analyze(_ plugin: MUSHclientPlugin) -> PluginImportReport {
        let script = plugin.script
        var findings: [PluginImportReport.Finding] = []

        // One reassuring line for the supported surface (no method list — that
        // detail is noise for the player; what matters is what *won't* work).
        let usedSupported = supported.filter { contains(script, word: $0) }
        if !usedSupported.isEmpty {
            findings.append(.init(
                severity: .ok,
                message: "Uses \(usedSupported.count) supported MUSHclient call(s)."
            ))
        }

        // Genuine limitations a player would notice (one finding each).
        for method in partial.keys.sorted() where contains(script, word: method) {
            findings.append(.init(severity: .warning, message: partial[method] ?? ""))
        }
        for method in unsupported.keys.sorted() where contains(script, word: method) {
            findings.append(.init(severity: .error, message: unsupported[method] ?? ""))
        }

        // Miniwindows: a warning, not a blocker. The plugin's commands and
        // automations still run; only its self-drawn on-screen panel is absent
        // (Proteles doesn't host plugin windows yet).
        if script.range(of: "\\bWindow[A-Za-z]+\\b", options: .regularExpression) != nil {
            findings.append(.init(
                severity: .warning,
                message: "Draws its own on-screen window, which Proteles doesn't show yet — "
                    + "its commands still work, but you won't see that custom panel."
            ))
        }

        // Companion files: a plugin that loads sibling Lua from its own folder
        // needs the whole folder, which Import (a single-file copy) won't bring.
        if loadsCompanionFiles(script) {
            findings.append(.init(
                severity: .warning,
                message: "Loads companion files from its own folder. Add it with “Add Local…” "
                    + "(pointing at its folder) so they're found — Import copies only the .xml."
            ))
        }

        // require'd libraries (luacom is reported above as unsupported).
        for library in requiredLibraries(in: script) where library != "luacom" {
            if bundledLibraries.contains(library) {
                findings.append(.init(severity: .ok, message: "Uses the bundled `\(library)` helper."))
            } else if stubbedLibraries.contains(library) {
                findings.append(.init(
                    severity: .warning,
                    message: "Its online-update / background-download features (`\(library)`) won't run; "
                        + "everything else loads."
                ))
            } else {
                findings.append(.init(
                    severity: .warning,
                    message: "Needs a helper file (`\(library).lua`) alongside the plugin in its folder."
                ))
            }
        }

        return PluginImportReport(
            name: plugin.name,
            id: plugin.id,
            author: plugin.author,
            version: plugin.version,
            triggerCount: plugin.triggers.count,
            aliasCount: plugin.aliases.count,
            timerCount: plugin.timers.count,
            findings: findings
        )
    }

    // MARK: - Private

    private static func contains(_ source: String, word: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// True if the script `dofile`s a file built from its own directory
    /// (`dofile(GetPluginInfo(…, 20) .. "x.lua")` / `dofile(GetInfo(60) .. …)`)
    /// — i.e. it has sibling modules that must travel with it.
    private static func loadsCompanionFiles(_ source: String) -> Bool {
        let pattern = #"dofile\s*\(\s*Get(PluginInfo|Info)\b"#
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// Library names from `require "x"` / `require('x')` calls.
    private static func requiredLibraries(in source: String) -> [String] {
        let pattern = #"require\s*\(?\s*["']([A-Za-z0-9_.]+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var names: [String] = []
        for match in regex.matches(in: source, range: range) {
            if let r = Range(match.range(at: 1), in: source) {
                let name = String(source[r])
                if !names.contains(name) { names.append(name) }
            }
        }
        return names.sorted()
    }
}
