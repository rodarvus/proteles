import Foundation

/// Incremental ANSI escape-sequence parser (SGR styling + minimal CSI).
///
/// Consumes data bytes — typically the ``TelnetEvent/data(_:)`` stream
/// from ``TelnetProcessor`` — and emits ``ANSIEvent`` values. The parser
/// is **stateful across calls**: byte slices may cut through the middle
/// of a CSI sequence or a UTF-8 character; both cases are buffered and
/// recombined transparently.
///
/// SGR semantics (PLAN.md §5.4):
/// - SGR 0 / empty params: reset to default
/// - SGR 1, 2, 3, 4, 7, 9: bold, dim, italic, underline, reverse, strike
/// - SGR 22, 23, 24, 27, 29: corresponding resets (22 clears bold *and* dim)
/// - SGR 5/6 (blink), 8 (conceal): parsed but ignored
/// - SGR 30–37 / 40–47 / 90–97 / 100–107: named & bright named fg/bg
/// - SGR 38;5;N / 48;5;N: 8-bit palette
/// - SGR 38;2;R;G;B / 48;2;R;G;B: 24-bit RGB
/// - SGR 39 / 49: default fg / bg
///
/// Non-SGR CSI sequences are emitted as ``ANSIEvent/unhandledCSI(final:parameters:)``
/// so consumers can ignore them cleanly without us having to guess at
/// semantics.
///
/// UTF-8 decoding: a partial multi-byte sequence at a chunk boundary is
/// held back from the emitted text and joined to the next chunk. Invalid
/// bytes follow Swift's default UTF-8 decoding, producing `U+FFFD`.
public struct ANSIParser: Sendable {
    public private(set) var currentStyle: StyleAttributes = .default

    private enum State: Equatable {
        case ground
        case escape
        case csi
    }

    private var state: State = .ground
    private var csiParams: String = ""
    private var pendingTextBytes: [UInt8] = []
    private var utf8HoldBuffer: [UInt8] = []

    public init() {}

    /// Feed bytes into the parser. `emit` is invoked once per event in
    /// emission order.
    public mutating func process(
        _ bytes: some Sequence<UInt8>,
        emit: (ANSIEvent) -> Void
    ) {
        for byte in bytes {
            processSingle(byte, emit: emit)
        }
    }

    /// Flush any buffered text. Call this at end-of-stream or when you
    /// need a synchronous boundary (e.g. before showing a prompt).
    /// Partial UTF-8 sequences that have not yet completed are *not*
    /// emitted — they remain held until more bytes arrive.
    public mutating func flush(_ emit: (ANSIEvent) -> Void) {
        flushText(emit: emit)
    }

    /// Reset state to initial. Call between connections.
    public mutating func reset() {
        state = .ground
        currentStyle = .default
        csiParams.removeAll(keepingCapacity: false)
        pendingTextBytes.removeAll(keepingCapacity: false)
        utf8HoldBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - State machine

    private mutating func processSingle(
        _ byte: UInt8,
        emit: (ANSIEvent) -> Void
    ) {
        switch state {
        case .ground:
            processGround(byte, emit: emit)
        case .escape:
            processEscape(byte)
        case .csi:
            processCSI(byte, emit: emit)
        }
    }

    private mutating func processGround(
        _ byte: UInt8,
        emit: (ANSIEvent) -> Void
    ) {
        switch byte {
        case 0x1B:
            flushText(emit: emit)
            state = .escape
        case 0x0A:
            flushText(emit: emit)
            emit(.lineFeed)
        case 0x0D:
            flushText(emit: emit)
            emit(.carriageReturn)
        case 0x07:
            flushText(emit: emit)
            emit(.bell)
        case 0x08:
            flushText(emit: emit)
            emit(.backspace)
        case 0x09:
            flushText(emit: emit)
            emit(.tab)
        case 0x00...0x06,
             0x0B,
             0x0C,
             0x0E...0x1A,
             0x1C...0x1F,
             0x7F:
            flushText(emit: emit)
            emit(.otherControl(byte))
        default:
            pendingTextBytes.append(byte)
        }
    }

    private mutating func processEscape(_ byte: UInt8) {
        switch byte {
        case 0x5B:
            state = .csi
            csiParams.removeAll(keepingCapacity: true)
        default:
            // ESC followed by something other than '[' — Aardwolf doesn't
            // use these (DCS, OSC, etc.). Drop and return to ground.
            state = .ground
        }
    }

    private mutating func processCSI(
        _ byte: UInt8,
        emit: (ANSIEvent) -> Void
    ) {
        switch byte {
        case 0x30...0x3F:
            // Parameter bytes: digits, ';', ':', '?', etc.
            csiParams.append(Character(Unicode.Scalar(byte)))
        case 0x20...0x2F:
            // Intermediate bytes — not used by Aardwolf SGR; ignore.
            break
        case 0x40...0x7E:
            processCSIFinal(byte, emit: emit)
            state = .ground
        default:
            // Out-of-range byte inside CSI — abort and return to ground.
            state = .ground
        }
    }

    private mutating func processCSIFinal(
        _ final: UInt8,
        emit: (ANSIEvent) -> Void
    ) {
        let params = parseSGRParams(csiParams)
        switch final {
        case 0x6D: // 'm' — SGR
            flushText(emit: emit)
            applySGR(params)
        default:
            flushText(emit: emit)
            emit(.unhandledCSI(final: final, parameters: params))
        }
    }

    // MARK: - SGR

    private func parseSGRParams(_ paramString: String) -> [Int] {
        if paramString.isEmpty { return [0] }
        return paramString
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
    }

    private mutating func applySGR(_ params: [Int]) {
        var index = 0
        while index < params.count {
            let consumed = applySGRParameter(params, at: index)
            index += consumed
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func applySGRParameter(
        _ params: [Int],
        at index: Int
    ) -> Int {
        let param = params[index]
        switch param {
        case 0:
            currentStyle = .default
        case 1:
            currentStyle.bold = true
        case 2:
            currentStyle.dim = true
        case 3:
            currentStyle.italic = true
        case 4:
            currentStyle.underline = true
        case 7:
            currentStyle.reverse = true
        case 9:
            currentStyle.strikethrough = true
        case 22:
            currentStyle.bold = false
            currentStyle.dim = false
        case 23:
            currentStyle.italic = false
        case 24:
            currentStyle.underline = false
        case 27:
            currentStyle.reverse = false
        case 29:
            currentStyle.strikethrough = false
        case 30...37:
            if let color = NamedColor(rawValue: UInt8(param - 30)) {
                currentStyle.foreground = .named(color)
            }
        case 39:
            currentStyle.foreground = nil
        case 40...47:
            if let color = NamedColor(rawValue: UInt8(param - 40)) {
                currentStyle.background = .named(color)
            }
        case 49:
            currentStyle.background = nil
        case 90...97:
            if let color = NamedColor(rawValue: UInt8(param - 90)) {
                currentStyle.foreground = .brightNamed(color)
            }
        case 100...107:
            if let color = NamedColor(rawValue: UInt8(param - 100)) {
                currentStyle.background = .brightNamed(color)
            }
        case 38:
            return 1 + applyExtendedColor(params, at: index + 1, isForeground: true)
        case 48:
            return 1 + applyExtendedColor(params, at: index + 1, isForeground: false)
        default:
            break
        }
        return 1
    }

    /// Handles the 8-bit (`;5;N`) and 24-bit (`;2;R;G;B`) extended-colour
    /// forms after a leading 38 or 48. Returns the number of additional
    /// parameters consumed beyond the leading 38/48.
    private mutating func applyExtendedColor(
        _ params: [Int],
        at index: Int,
        isForeground: Bool
    ) -> Int {
        guard index < params.count else { return 0 }
        let kind = params[index]
        switch kind {
        case 5:
            guard index + 1 < params.count else { return 1 }
            let value = clampUInt8(params[index + 1])
            assignColor(.palette(value), isForeground: isForeground)
            return 2
        case 2:
            guard index + 3 < params.count else { return 1 }
            let red = clampUInt8(params[index + 1])
            let green = clampUInt8(params[index + 2])
            let blue = clampUInt8(params[index + 3])
            assignColor(
                .rgb(red: red, green: green, blue: blue),
                isForeground: isForeground
            )
            return 4
        default:
            return 1
        }
    }

    private mutating func assignColor(
        _ color: ANSIColor,
        isForeground: Bool
    ) {
        if isForeground {
            currentStyle.foreground = color
        } else {
            currentStyle.background = color
        }
    }

    private func clampUInt8(_ value: Int) -> UInt8 {
        UInt8(max(0, min(255, value)))
    }

    // MARK: - Text buffer / UTF-8

    private mutating func flushText(emit: (ANSIEvent) -> Void) {
        guard !pendingTextBytes.isEmpty || !utf8HoldBuffer.isEmpty else { return }

        var combined = utf8HoldBuffer
        utf8HoldBuffer.removeAll(keepingCapacity: true)
        combined.append(contentsOf: pendingTextBytes)
        pendingTextBytes.removeAll(keepingCapacity: true)

        let safeEnd = safeUTF8DecodeEnd(in: combined)
        if safeEnd < combined.count {
            utf8HoldBuffer.append(contentsOf: combined[safeEnd...])
        }

        let decodable = combined.prefix(safeEnd)
        guard !decodable.isEmpty else { return }

        let text = String(decoding: decodable, as: UTF8.self)
        emit(.text(text, currentStyle))
    }

    /// Walks `bytes` backwards looking for the last position that does
    /// not split a multi-byte UTF-8 sequence. Returns the byte count up
    /// to (and including) that safe position. Invalid leading bytes are
    /// passed through to Swift's UTF-8 decoder (which substitutes
    /// `U+FFFD`).
    private func safeUTF8DecodeEnd(in bytes: [UInt8]) -> Int {
        let count = bytes.count
        guard count > 0 else { return 0 }

        var lookback = count - 1
        var continuations = 0
        while lookback >= 0 {
            let byte = bytes[lookback]
            if byte < 0x80 {
                return count
            }
            if byte & 0xC0 == 0x80 {
                continuations += 1
                lookback -= 1
                continue
            }
            // Leading byte found.
            let needed: Int
            switch byte & 0xF8 {
            case 0xF0:
                needed = 3
            default:
                switch byte & 0xF0 {
                case 0xE0:
                    needed = 2
                default:
                    if byte & 0xE0 == 0xC0 {
                        needed = 1
                    } else {
                        // Invalid leading byte — let the decoder handle it.
                        return count
                    }
                }
            }
            if continuations >= needed { return count }
            return lookback
        }
        // All bytes are continuations (malformed) — flush and let the
        // decoder replace.
        return count
    }
}
