import Foundation

/// Makes Search-and-Destroy's plugin XML strict enough for `XMLParser`.
///
/// S&D's `<trigger>`/`<alias>` `match="…"` attributes embed PCRE regexes with
/// named-capture groups like `(?<mob_name>…)` and lookbehinds — whose bare
/// `<`/`>` are illegal inside an XML attribute value, so `XMLParser` (SAX)
/// rejects the document (error 111). MUSHclient's own loader is lenient; ours
/// isn't.
///
/// This normaliser is a small, deterministic state machine that escapes `<`
/// and `>` **only inside attribute values**, leaving everything else — element
/// text, the giant `<script><![CDATA[…]]></script>` body, and comments —
/// byte-for-byte untouched. `XMLParser` then decodes `&lt;`/`&gt;` back to
/// `<`/`>` when it hands us the attribute string, so the regexes survive
/// intact. CDATA and comment sections are copied verbatim (they legally carry
/// `<`/`>` already).
enum SearchAndDestroyXML {
    static func normalise(_ xml: String) -> String {
        var scanner = Scanner(xml)
        scanner.run()
        return scanner.output
    }

    /// Single-pass scalar scanner. Mutating struct (used locally, never shared).
    private struct Scanner {
        let scalars: [Unicode.Scalar]
        let end: Int
        var index = 0
        var output = ""

        /// Inside a `<…>` tag? And, if so, inside which quote char?
        var inTag = false
        var quote: Unicode.Scalar?

        static let lt = Unicode.Scalar(UInt8(ascii: "<"))
        static let gt = Unicode.Scalar(UInt8(ascii: ">"))
        static let dq = Unicode.Scalar(UInt8(ascii: "\""))
        static let sq = Unicode.Scalar(UInt8(ascii: "'"))

        init(_ xml: String) {
            scalars = Array(xml.unicodeScalars)
            end = scalars.count
            output.reserveCapacity(scalars.count + 256)
        }

        mutating func run() {
            while index < end {
                if inTag { stepInTag() } else { stepInText() }
            }
        }

        /// Outside a tag: pass CDATA/comments through verbatim; detect tag open.
        mutating func stepInText() {
            if matches("<![CDATA[") {
                emit("<![CDATA["); index += 9; copyThrough("]]>"); return
            }
            if matches("<!--") {
                emit("<!--"); index += 4; copyThrough("-->"); return
            }
            let scalar = scalars[index]
            if scalar == Self.lt {
                inTag = true
                quote = nil
            }
            output.unicodeScalars.append(scalar)
            index += 1
        }

        /// Inside a tag: escape `<`/`>` within a quoted attribute value.
        mutating func stepInTag() {
            let scalar = scalars[index]
            if let active = quote {
                switch scalar {
                case active: quote = nil; output.unicodeScalars.append(scalar)
                case Self.lt: emit("&lt;")
                case Self.gt: emit("&gt;")
                default: output.unicodeScalars.append(scalar)
                }
            } else {
                switch scalar {
                case Self.dq, Self.sq: quote = scalar; output.unicodeScalars.append(scalar)
                case Self.gt: inTag = false; output.unicodeScalars.append(scalar)
                default: output.unicodeScalars.append(scalar)
                }
            }
            index += 1
        }

        func matches(_ literal: String) -> Bool {
            let lit = Array(literal.unicodeScalars)
            guard index + lit.count <= end else { return false }
            for offset in 0..<lit.count where scalars[index + offset] != lit[offset] {
                return false
            }
            return true
        }

        /// Copy verbatim from `index` until just past `terminator`.
        mutating func copyThrough(_ terminator: String) {
            let term = Array(terminator.unicodeScalars)
            while index < end {
                if matches(terminator) {
                    for offset in 0..<term.count {
                        output.unicodeScalars.append(scalars[index + offset])
                    }
                    index += term.count
                    return
                }
                output.unicodeScalars.append(scalars[index])
                index += 1
            }
        }

        mutating func emit(_ text: String) {
            output += text
        }
    }
}
