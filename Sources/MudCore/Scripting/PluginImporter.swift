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
    /// World-API methods that are fully supported by the shim.
    private static let supported: Set<String> = [
        "Send", "SendNoEcho", "Execute", "Note", "Tell", "AnsiNote", "ColourTell",
        "GetVariable", "SetVariable", "DeleteVariable", "GetPluginVariable",
        "GetPluginID", "BroadcastPlugin", "IsConnected", "Send_GMCP_Packet", "Trim",
        "print", "require", "dofile", "loadstring"
    ]

    /// Methods that work but with limitations — message per method.
    private static let partial: [String: String] = [
        "ColourNote": "single colour per line (multi-colour segments are merged)",
        "GetInfo": "common values only; some return stubs",
        "GetPluginInfo": "plugin directory (infotype 20) only",
        "CallPlugin": "forwards to exported functions; no per-plugin call routing",
        "EnableTrigger": "currently a no-op (name-based enable pending)",
        "EnableTimer": "currently a no-op (name-based enable pending)",
        "EnableGroup": "currently a no-op (name-based enable pending)"
    ]

    /// Methods that are not implemented — message per method.
    private static let unsupported: [String: String] = [
        "AddTriggerEx": "programmatic triggers aren't supported (declarative `<triggers>` are)",
        "AddAlias": "programmatic aliases aren't supported (declarative `<aliases>` are)",
        "AddTimer": "programmatic timers aren't supported (declarative `<timers>` are)",
        "SetCursor": "not supported",
        "Hyperlink": "clickable hyperlinks aren't supported yet"
    ]

    /// Helper libraries Proteles bundles for `require`.
    private static let bundledLibraries: Set<String> = [
        "gmcphelper", "serialize", "json", "aardwolf_colors",
        "tprint", "copytable", "commas", "pairsbykeys"
    ]

    public static func analyze(_ plugin: MUSHclientPlugin) -> PluginImportReport {
        let script = plugin.script
        var findings: [PluginImportReport.Finding] = []

        // Supported methods used → one summary line.
        let usedSupported = supported.filter { contains(script, word: $0) }.sorted()
        if !usedSupported.isEmpty {
            let list = usedSupported.joined(separator: ", ")
            findings.append(.init(
                severity: .ok,
                message: "Uses \(usedSupported.count) supported call(s): \(list)"
            ))
        }

        // Partial / unsupported methods → one finding each.
        for method in partial.keys.sorted() where contains(script, word: method) {
            findings.append(.init(severity: .warning, message: "`\(method)`: \(partial[method] ?? "")"))
        }
        for method in unsupported.keys.sorted() where contains(script, word: method) {
            findings.append(.init(severity: .error, message: "`\(method)`: \(unsupported[method] ?? "")"))
        }

        // Miniwindows (any Window* call) and Windows COM.
        if script.range(of: "\\bWindow[A-Za-z]+\\b", options: .regularExpression) != nil {
            findings.append(.init(
                severity: .error,
                message: "Uses miniwindows (Window*) — not supported; needs a native port"
            ))
        }
        if contains(script, word: "luacom") {
            findings.append(.init(severity: .error, message: "Uses luacom (Windows COM) — not supported"))
        }

        // require'd libraries.
        for library in requiredLibraries(in: script) {
            if bundledLibraries.contains(library) {
                findings.append(.init(severity: .ok, message: "Requires `\(library)` — bundled"))
            } else {
                findings.append(.init(
                    severity: .warning,
                    message: "Requires `\(library)` — not bundled; must be in the plugin's folder"
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
