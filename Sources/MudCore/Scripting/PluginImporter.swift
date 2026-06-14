import Foundation

/// A compatibility report for a MUSHclient plugin being added (ARCHITECTURE.md §7.5),
/// shown before install so the player knows whether it'll work.
///
/// Design principle (the player's mental model): **if the plugin works the way
/// it does in MUSHclient, say nothing.** A report is reassuring by default —
/// it surfaces a finding only when there's something to *know* (a minor caveat)
/// or something to *do* (a needed file wasn't included). No green "uses N
/// supported calls" noise, no warning for things that actually work.
public struct PluginImportReport: Sendable, Equatable {
    /// How a finding bears on the plugin. Only two: a neutral `info` note about
    /// a minor caveat (it still works), and an actionable `warning` that
    /// something it needs is missing. **Only a `warning` lowers the verdict.**
    public enum Severity: Sendable, Equatable, Comparable {
        case info, warning
    }

    /// The two outcomes a player cares about.
    public enum Verdict: Sendable, Equatable {
        /// Loads and runs. Any notes are minor (a pop-up panel won't draw, a
        /// Windows-only extra is skipped) and don't stop it working.
        case ready
        /// Something it needs wasn't included — usually because only the `.xml`
        /// was added, not the whole plugin folder. The player has one action.
        case needsAttention
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
        findings.contains { $0.severity == .warning } ? .needsAttention : .ready
    }
}

/// Analyses a parsed MUSHclient plugin against Proteles' supported surface.
///
/// Heuristic but **folder-aware**: it scans the plugin's `<script>` for the
/// files it loads (`require`/`dofile`) and resolves each against what Proteles
/// bundles, the Lua standard library, and the files actually present alongside
/// the plugin (`availableFiles`). It warns only about the genuine remainder —
/// so a plugin added as its complete folder, with its helpers beside it, reads
/// clean, exactly as it would run.
public enum PluginImporter {
    /// Helper libraries Proteles bundles for `require`/`dofile` (the single
    /// source of truth is the shim's registration — kept in sync here). `wait`,
    /// `check`, `async`, and the dependency-nag stubs are registered separately.
    private static var bundledLibraries: Set<String> {
        Set(LuaRuntime.standardHelpers.keys)
            .union(["wait", "check", "async", "checkplugin", "aard_requirements"])
    }

    /// Lua 5.1 standard libraries. `require "string"` / `"math"` resolve to the
    /// already-loaded global table (never a missing file).
    private static let standardLibraries: Set<String> = [
        "string", "math", "table", "os", "io", "coroutine", "debug", "package"
    ]

    public static func analyze(
        _ plugin: MUSHclientPlugin,
        availableFiles: Set<String> = []
    ) -> PluginImportReport {
        let script = plugin.script
        var findings: [PluginImportReport.Finding] = []

        // Soft notes (info) — the plugin works; these are heads-ups, not faults,
        // so they don't move the verdict off "Ready to use".
        if script.range(of: "\\bWindow[A-Za-z]+\\b", options: .regularExpression) != nil {
            findings.append(.init(
                severity: .info,
                message: "Draws its own pop-up window — Proteles renders these natively "
                    + "(text, shapes, images, clickable buttons; drag to move, position is "
                    + "remembered). A few advanced effects (image filters, blend modes, "
                    + "draw-behind-text) are approximated or skipped."
            ))
        }
        if contains(script, word: "luacom") {
            findings.append(.init(
                severity: .info,
                message: "Uses a Windows-only feature (sharing data with other programs) that "
                    + "can't run on macOS — the rest of the plugin works."
            ))
        }

        // The one actionable warning: files the plugin loads that weren't bundled,
        // aren't part of Lua, and weren't included alongside it.
        let missing = missingFiles(script, availableFiles: availableFiles)
        if !missing.isEmpty {
            findings.append(.init(
                severity: .warning,
                message: "Needs file(s) that weren't included: \(missing.joined(separator: ", ")). "
                    + "Add the whole plugin folder (not just the .xml) so they're found."
            ))
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

    // MARK: - Resolution

    /// The `.lua` files the script loads (via `require` or `dofile`) that can't
    /// be resolved — i.e. not bundled, not a Lua standard library, and not
    /// present in `availableFiles`. Returned as sorted filenames (`var.lua`, …).
    private static func missingFiles(_ script: String, availableFiles: Set<String>) -> [String] {
        var missing: Set<String> = []

        for name in requiredLibraries(in: script) {
            // luacom gets a COM info note above; not a missing file. (`async` is
            // bundled, so the next check already covers it.)
            if name == "luacom" { continue }
            if standardLibraries.contains(name) || bundledLibraries.contains(name) { continue }
            if availableFiles.contains((name + ".lua").lowercased()) { continue }
            missing.insert(name + ".lua")
        }

        for base in companionBasenames(in: script) {
            let stem = base.hasSuffix(".lua") ? String(base.dropLast(4)) : base
            if standardLibraries.contains(stem) || bundledLibraries.contains(stem) { continue }
            if availableFiles.contains(base.lowercased()) { continue }
            missing.insert(base)
        }

        return missing.sorted()
    }

    private static func contains(_ source: String, word: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return source.range(of: pattern, options: .regularExpression) != nil
    }

    /// Library names from `require "x"` / `require('x')` calls.
    private static func requiredLibraries(in source: String) -> Set<String> {
        captures(in: source, pattern: #"require\s*\(?\s*["']([A-Za-z0-9_.]+)["']"#)
    }

    /// `.lua` basenames the script `dofile`s — both a direct literal path
    /// (`dofile("x/foo.lua")`) and the common concatenated form
    /// (`dofile(GetPluginInfo(…, 20) .. "foo.lua")`). A fully dynamic `dofile`
    /// (a path built only from variables) yields no basename, so it isn't
    /// guessed at — better silent than a false alarm.
    private static func companionBasenames(in source: String) -> Set<String> {
        // Any quoted string ending in `.lua` that is concatenated (`.. "foo.lua"`)
        // or passed directly to dofile/loadfile. Take the path's last component.
        let literals = captures(in: source, pattern: #"["']([^"']*\.lua)["']"#)
            .union(captures(in: source, pattern: #"\[\[([^\]]*\.lua)\]\]"#))
        // Only count those that look like a loaded file (appear near dofile/
        // loadfile/require or a `..` concatenation), not a .lua mentioned in a
        // Note. Cheap proxy: the script references dofile/loadfile at all.
        guard source.range(of: #"\b(dofile|loadfile)\b"#, options: .regularExpression) != nil
        else { return [] }
        return Set(literals
            .map { ($0.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent })
    }

    /// First capture group of every match of `pattern` in `source`.
    private static func captures(in source: String, pattern: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        var names: Set<String> = []
        for match in regex.matches(in: source, range: range) {
            if let r = Range(match.range(at: 1), in: source) {
                names.insert(String(source[r]))
            }
        }
        return names
    }
}
