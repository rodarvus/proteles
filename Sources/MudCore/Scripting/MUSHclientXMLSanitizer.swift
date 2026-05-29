import Foundation

/// Makes MUSHclient plugin XML acceptable to the strict `XMLParser` (libxml2)
/// without altering its meaning.
///
/// MUSHclient's own XML reader is lenient: plugins routinely put **raw `<` and
/// `>`** inside attribute values — most commonly PCRE named-group regexes in a
/// trigger's `match=`, e.g. `match="^\{sfail\}(?<sn>[0-9]+),(?<tg>[0-9]+)"`.
/// That's malformed XML (`<` must be `&lt;` in an attribute value), so
/// `XMLParser` rejects the whole file ("Unescaped '<' not allowed in attributes
/// values") and the importer reports "not a valid plugin". libxml2's recovery
/// mode "parses" it but drops/mangles the offending attribute, corrupting the
/// regex — so instead we escape the offenders up front and keep the pattern.
///
/// Operates on **bytes**, so it's encoding-agnostic (the chars it touches —
/// `<`, `>`, `&` — are single ASCII bytes in both UTF-8 and the Latin-1 some
/// plugins declare; everything else passes through untouched), and only inside
/// double/single-quoted **attribute values**: CDATA (`<script>` Lua bodies),
/// comments, processing instructions, the XML declaration, and the DOCTYPE are
/// copied verbatim, and existing entities (`&lt;`, `&amp;`, `&#10;`) are left
/// alone (so it's idempotent on already-valid files).
enum MUSHclientXMLSanitizer {
    private enum State { case text, tag, attribute }

    private static let ltBytes = [UInt8]("&lt;".utf8)
    private static let gtBytes = [UInt8]("&gt;".utf8)
    private static let ampBytes = [UInt8]("&amp;".utf8)

    static func lenientAttributeData(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 64)
        var state = State.text
        var quote: UInt8 = 0
        var i = 0

        while i < bytes.count {
            let byte = bytes[i]
            switch state {
            case .text:
                if byte == ascii("<"), let next = passSpecialRegion(bytes, at: i, into: &out) {
                    i = next // CDATA / comment / PI / DOCTYPE copied verbatim
                    continue
                }
                if byte == ascii("<") { state = .tag }
                out.append(byte)
            case .tag:
                if byte == ascii("\"") || byte == ascii("'") {
                    quote = byte
                    state = .attribute
                } else if byte == ascii(">") {
                    state = .text
                }
                out.append(byte)
            case .attribute:
                if byte == quote {
                    state = .tag
                    out.append(byte)
                } else {
                    escapeAttributeByte(byte, bytes, at: i, into: &out)
                }
            }
            i += 1
        }
        return Data(out)
    }

    // MARK: - Helpers

    /// Escape a byte inside an attribute value (`<`→`&lt;`, `>`→`&gt;`, a bare
    /// `&`→`&amp;`); everything else (incl. valid entities) passes through.
    private static func escapeAttributeByte(
        _ byte: UInt8, _ bytes: [UInt8], at index: Int, into out: inout [UInt8]
    ) {
        if byte == ascii("<") {
            out += ltBytes
        } else if byte == ascii(">") {
            out += gtBytes
        } else if byte == ascii("&"), !startsEntity(bytes, at: index) {
            out += ampBytes
        } else {
            out.append(byte)
        }
    }

    /// If a markup region whose contents must be copied verbatim (CDATA,
    /// comment, processing instruction, or DOCTYPE/declaration) starts at
    /// `index`, copy it through and return the index just past it; else `nil`
    /// (an ordinary start/end tag).
    private static func passSpecialRegion(
        _ bytes: [UInt8], at index: Int, into out: inout [UInt8]
    ) -> Int? {
        if matches("<![CDATA[", bytes, at: index) { return copyThrough("]]>", bytes, from: index, into: &out)
        }
        if matches("<!--", bytes, at: index) { return copyThrough("-->", bytes, from: index, into: &out) }
        if matches("<?", bytes, at: index) { return copyThrough("?>", bytes, from: index, into: &out) }
        if matches("<!", bytes, at: index) { return copyThrough(">", bytes, from: index, into: &out) }
        return nil
    }

    private static func ascii(_ char: Character) -> UInt8 {
        char.asciiValue!
    }

    /// Whether the ASCII `literal` occurs at `index` in `bytes`.
    private static func matches(_ literal: String, _ bytes: [UInt8], at index: Int) -> Bool {
        let seq = [UInt8](literal.utf8)
        guard index + seq.count <= bytes.count else { return false }
        for offset in seq.indices where bytes[index + offset] != seq[offset] {
            return false
        }
        return true
    }

    /// Copy bytes from `from` up to and including the next `terminator`, into
    /// `out`; return the index just past it. If not found, copy the remainder.
    private static func copyThrough(
        _ terminator: String, _ bytes: [UInt8], from: Int, into out: inout [UInt8]
    ) -> Int {
        let seq = [UInt8](terminator.utf8)
        var j = from
        while j < bytes.count {
            if matches(terminator, bytes, at: j) {
                out.append(contentsOf: bytes[from..<(j + seq.count)])
                return j + seq.count
            }
            j += 1
        }
        out.append(contentsOf: bytes[from..<bytes.count])
        return bytes.count
    }

    /// Whether the `&` at `index` begins a well-formed entity reference
    /// (`&name;`, `&#123;`, or `&#xAB;`) — left untouched if so.
    private static func startsEntity(_ bytes: [UInt8], at index: Int) -> Bool {
        var j = index + 1
        let count = bytes.count
        guard j < count else { return false }
        if bytes[j] == ascii("#") {
            j += 1
            if j < count, bytes[j] == ascii("x") || bytes[j] == ascii("X") { j += 1 }
            let start = j
            while j < count, isHexOrDigit(bytes[j]) {
                j += 1
            }
            return j > start && j < count && bytes[j] == ascii(";")
        }
        let start = j
        while j < count, isNameByte(bytes[j]) {
            j += 1
        }
        return j > start && j < count && bytes[j] == ascii(";")
    }

    private static func isHexOrDigit(_ byte: UInt8) -> Bool {
        (byte >= ascii("0") && byte <= ascii("9"))
            || (byte >= ascii("a") && byte <= ascii("f"))
            || (byte >= ascii("A") && byte <= ascii("F"))
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= ascii("a") && byte <= ascii("z"))
            || (byte >= ascii("A") && byte <= ascii("Z"))
            || (byte >= ascii("0") && byte <= ascii("9"))
    }
}
