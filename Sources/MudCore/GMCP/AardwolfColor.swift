import Foundation

/// Parses Aardwolf's `@`-colour codes into a styled ``Line``.
///
/// Aardwolf publishes chat/channel text (via `comm.channel` GMCP) using its
/// own colour markup rather than ANSI (mapping verified against
/// `aardwolfclientpackage/.../aardwolf_colors.lua`):
///
///   - `@@` → a literal `@`.
///   - `@x` followed by 1–3 digits → an xterm palette colour
///     (`ANSIColor.palette`), clamped to 0…255.
///   - `@` + a single colour letter sets the foreground:
///     `k r g y b m c w` are the normal colours, and `D R G Y B M C W`
///     their bright variants.
///   - Any other `@x` two-char code is dropped (no text, no style change).
///
/// The result reuses the same ``Line`` / ``StyledRun`` model as the main
/// output, so the chat window renders with identical colour handling.
public enum AardwolfColor {
    private static let normal: [Character: NamedColor] = [
        "k": .black, "r": .red, "g": .green, "y": .yellow,
        "b": .blue, "m": .magenta, "c": .cyan, "w": .white
    ]
    private static let bright: [Character: NamedColor] = [
        "D": .black, "R": .red, "G": .green, "Y": .yellow,
        "B": .blue, "M": .magenta, "C": .cyan, "W": .white
    ]

    /// Convert an Aardwolf-coded string into a styled ``Line``. The `@`
    /// codes are consumed; ``Line/text`` holds the visible text and
    /// ``Line/runs`` the coloured spans (UTF-16 ranges).
    public static func styledLine(
        from coded: String,
        id: LineID = LineID(0),
        timestamp: Date = Date()
    ) -> Line {
        var text = ""
        var runs: [StyledRun] = []
        var currentColor: ANSIColor?
        var runStart = 0 // UTF-16 offset where the current colour run began

        func closeRun(at end: Int) {
            guard let color = currentColor, runStart < end else { return }
            runs.append(StyledRun(
                utf16Range: runStart..<end,
                style: StyleAttributes(foreground: color)
            ))
        }

        func setColor(_ color: ANSIColor?) {
            let end = text.utf16.count
            closeRun(at: end)
            currentColor = color
            runStart = end
        }

        var chars = Substring(coded)
        while let char = chars.first {
            guard char == "@" else {
                text.append(char)
                chars = chars.dropFirst()
                continue
            }
            chars = chars.dropFirst() // consume '@'
            guard let code = chars.first else { break } // lone trailing '@'
            chars = chars.dropFirst() // consume the code char

            switch code {
            case "@":
                text.append("@")
            case "x":
                let digits = chars.prefix { $0.isNumber }.prefix(3)
                chars = chars.dropFirst(digits.count)
                if let value = Int(digits) {
                    setColor(.palette(UInt8(min(value, 255))))
                }
            default:
                if let named = normal[code] {
                    setColor(.named(named))
                } else if let named = bright[code] {
                    setColor(.brightNamed(named))
                }
                // Unknown code: dropped (already consumed).
            }
        }
        closeRun(at: text.utf16.count)

        return Line(id: id, timestamp: timestamp, text: text, runs: runs)
    }

    /// Strip all `@` colour codes, returning just the visible text.
    public static func stripped(_ coded: String) -> String {
        styledLine(from: coded).text
    }
}
