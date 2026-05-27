import Foundation
@testable import MudCore
import Testing

/// Coverage guard for the MUSHclient host-API surface Search-and-Destroy
/// relies on. Rather than discovering missing/stubbed primitives one live
/// test at a time, this extracts every MUSHclient-style call in the vendored
/// `core.lua` and asserts each resolves to a real value in the host runtime
/// after load. A new upstream call that we haven't bound fails here, in CI —
/// not in the user's hands.
@Suite("Search-and-Destroy — host API coverage")
struct SearchAndDestroyAPICoverageTests {
    init() {
        SnDFixture.install()
    }

    /// Identifiers that look like calls but aren't Lua globals we must provide:
    /// SQL keywords that appear inside query string literals in core.lua.
    private static let sqlNoise: Set<String> = [
        "UNIQUE", "DISTINCT", "DATE", "SUM", "SELECT", "INSERT", "UPDATE",
        "DELETE", "FROM", "WHERE", "VALUES", "COUNT", "ORDER", "GROUP",
        "INNER", "LEFT", "JOIN", "ON", "AND", "OR", "AS", "INTO", "SET",
        "CREATE", "TABLE", "INDEX", "PRAGMA", "REPLACE", "NULL", "LIMIT",
        "COALESCE", "MAX", "MIN", "AVG", "CAST", "EXISTS", "NOCASE"
    ]

    /// Extract CamelCase identifiers used as calls (`Name(`), excluding method
    /// or field calls (`obj.Name(` / `obj:Name(`) and anything inside Lua
    /// string literals or comments (so mob names in the `xtest` Simulate data
    /// don't masquerade as API calls).
    private func calledGlobals(in source: String) -> Set<String> {
        let code = Self.stripStringsAndComments(source)
        // Not preceded by a word char, dot, or colon; starts uppercase.
        let pattern = #"(?<![\w.:])([A-Z][A-Za-z0-9_]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = code as NSString
        var names: Set<String> = []
        regex.enumerateMatches(in: code, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: code) else { return }
            let name = String(code[range])
            // Keep only mixed-case names (MUSHclient API is CamelCase); drop
            // ALL-CAPS SQL keywords.
            if name.contains(where: \.isLowercase) { names.insert(name) }
        }
        return names.subtracting(Self.sqlNoise)
    }

    /// Replace Lua string-literal and comment bodies with spaces so identifiers
    /// inside them aren't mistaken for calls. Handles `"…"`, `'…'`, long
    /// brackets `[[ … ]]`/`[=[ … ]=]`, line comments `-- …`, and long comments.
    private static func stripStringsAndComments(_ source: String) -> String {
        let chars = Array(source)
        var out = [Character]()
        out.reserveCapacity(chars.count)
        var i = 0
        func longBracketClose(from start: Int) -> Int? {
            // start points at '['; match [=*[ and return the level, else nil.
            var j = start + 1
            var level = 0
            while j < chars.count, chars[j] == "=" {
                level += 1; j += 1
            }
            return (j < chars.count && chars[j] == "[") ? level : nil
        }
        while i < chars.count {
            let ch = chars[i]
            // Line / long comments.
            if ch == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                if i + 2 < chars.count, chars[i + 2] == "[", let level = longBracketClose(from: i + 2) {
                    let close = "]" + String(repeating: "=", count: level) + "]"
                    i = Self.skip(chars, from: i + 2, until: close)
                } else {
                    while i < chars.count, chars[i] != "\n" {
                        i += 1
                    }
                }
                out.append(" ")
                continue
            }
            // Long-bracket string.
            if ch == "[", let level = longBracketClose(from: i) {
                let close = "]" + String(repeating: "=", count: level) + "]"
                i = Self.skip(chars, from: i, until: close)
                out.append(" ")
                continue
            }
            // Quoted string.
            if ch == "\"" || ch == "'" {
                i += 1
                while i < chars.count, chars[i] != ch {
                    if chars[i] == "\\" { i += 1 }
                    i += 1
                }
                i += 1
                out.append(" ")
                continue
            }
            out.append(ch)
            i += 1
        }
        return String(out)
    }

    /// Index just past the next occurrence of `marker` in `chars` at/after `from`.
    private static func skip(_ chars: [Character], from: Int, until marker: String) -> Int {
        let needle = Array(marker)
        var i = from
        while i < chars.count {
            if i + needle.count <= chars.count, Array(chars[i..<i + needle.count]) == needle {
                return i + needle.count
            }
            i += 1
        }
        return chars.count
    }

    @Test("Every MUSHclient global S&D calls resolves in the host after load")
    func everyCalledGlobalIsDefined() async throws {
        let core = try #require(SearchAndDestroyAssets.core, "core.lua resource missing")
        let host = try SearchAndDestroyHost()
        try await host.load()

        var missing: [String] = []
        for name in calledGlobals(in: core).sorted() {
            let kind = await host.evaluate("type(\(name))") ?? "nil"
            if kind == "nil" { missing.append(name) }
        }
        let report = missing.joined(separator: ", ")
        #expect(missing.isEmpty, "Undefined globals S&D core.lua calls: \(report)")
    }
}
