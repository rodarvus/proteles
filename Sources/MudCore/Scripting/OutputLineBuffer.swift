import Collections
import Foundation

/// What produced a displayed line — backs `GetLineInfo`'s note (4) / user (5)
/// flags. We don't model MUSHclient's log / bookmark / horizontal-rule line
/// flags (they stub to false).
public enum OutputLineKind: Sendable, Equatable {
    case mud // server output
    case note // a script Note/ColourNote/echo (MUSHclient COMMENT)
    case userInput // an echoed typed command (USER_INPUT)
}

/// One line in the runtime's output-buffer mirror.
public struct BufferedLine: Sendable, Equatable {
    public let id: UInt64
    public let timestamp: Date
    public let text: String
    public let runs: [StyledRun]
    public let kind: OutputLineKind

    public init(id: UInt64, timestamp: Date, text: String, runs: [StyledRun], kind: OutputLineKind) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.runs = runs
        self.kind = kind
    }
}

/// A bounded mirror of the displayed output lines, owned by ``LuaRuntime`` so
/// the MUSHclient output-buffer world functions (`GetLineCount` /
/// `GetLinesInBufferCount` / `GetLineInfo` / `GetStyleInfo` / `GetRecentLines`)
/// can answer **synchronously** — the same approach `GetInfo(280/281)` uses for
/// live output geometry, since a Lua call can't `await` the scrollback actor.
///
/// `SessionController` pushes each displayed line (post-gag, so the mirror
/// matches what the user sees) via ``LuaRuntime/recordOutputLine(...)``.
/// Semantics ported from MUSHclient (`methods_info.cpp`): line numbers are
/// 1-indexed buffer positions (1 = oldest still buffered); out-of-range → nil
/// (VT_EMPTY); an unknown infotype → nil (VT_NULL). Lengths/columns are UTF-8
/// **byte** counts, as in MUSHclient.
public struct OutputLineBuffer: Sendable {
    public private(set) var lines: Deque<BufferedLine> = []
    /// Running count of all lines pushed since connect — `GetLineCount`. Never
    /// decremented (we don't implement `DeleteLines`).
    public private(set) var totalReceived = 0
    /// When the session connected, for the elapsed-time infotype.
    public var connectedAt: Date?
    public let maxLines: Int

    public init(maxLines: Int = 1000) {
        self.maxLines = maxLines
    }

    public mutating func append(_ line: BufferedLine) {
        lines.append(line)
        totalReceived += 1
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    /// Clear on (re)connect and stamp the connect time for infotype 13.
    public mutating func reset(connectedAt: Date) {
        lines.removeAll(keepingCapacity: true)
        totalReceived = 0
        self.connectedAt = connectedAt
    }

    public var lineCount: Int { totalReceived }
    public var linesInBuffer: Int { lines.count }

    /// `GetLineInfo(lineNumber, infoType)`. `lineNumber` is 1-indexed (1 = oldest
    /// buffered line). The infotype-0 "all fields" table is assembled in the shim
    /// from these scalars.
    public func lineInfo(_ lineNumber: Int, _ infoType: Int) -> LuaValue {
        guard let line = line(at: lineNumber) else { return .nil }
        switch infoType {
        case 1: return .string(line.text)
        case 2: return .number(Double(line.text.utf8.count))
        case 3, 4, 5, 6, 7, 8: return Self.lineFlag(line, infoType)
        case 9: return .number(line.timestamp.timeIntervalSince1970)
        // MUSHclient numbers lines from 1 (`new CLine(++m_total_lines, …)`); our
        // LineID is 0-based, so present it +1 for a faithful `m_nLineNumber`.
        case 10: return .number(Double(line.id) + 1)
        case 11: return .number(Double(line.runs.count))
        case 12, 13: return .number(elapsed(line)) // high-res ticks / elapsed since connect
        default: return .nil
        }
    }

    /// `GetStyleInfo(lineNumber, styleNumber, infoType)`. Both indices 1-based.
    public func styleInfo(_ lineNumber: Int, _ styleNumber: Int, _ infoType: Int) -> LuaValue {
        guard let line = line(at: lineNumber),
              styleNumber >= 1, styleNumber <= line.runs.count
        else { return .nil }
        let run = line.runs[styleNumber - 1]
        switch infoType {
        case 1, 2, 3: return Self.styleText(line.text, run, infoType)
        case 4, 5, 6, 7: return Self.styleAction(run.link, infoType)
        case 8, 9, 10, 11, 12, 13: return Self.styleFlag(run.style, infoType)
        case 14: return .number(Double(Self.colourref(run.style.foreground, fallback: 0xC0_C0C0)))
        case 15: return .number(Double(Self.colourref(run.style.background, fallback: 0x00_0000)))
        default: return .nil
        }
    }

    /// `GetRecentLines(count)` — the last `count` lines' (stripped) text, joined
    /// with newlines.
    public func recentLines(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return lines.suffix(count).map(\.text).joined(separator: "\n")
    }

    private func line(at lineNumber: Int) -> BufferedLine? {
        guard lineNumber >= 1, lineNumber <= lines.count else { return nil }
        return lines[lineNumber - 1]
    }

    private func elapsed(_ line: BufferedLine) -> Double {
        guard let connectedAt else { return 0 }
        return line.timestamp.timeIntervalSince(connectedAt)
    }

    /// Boolean per-line flags (infotypes 3–8). We model note/user; hard_return,
    /// log, bookmark and horizontal-rule aren't tracked (stub).
    private static func lineFlag(_ line: BufferedLine, _ infoType: Int) -> LuaValue {
        switch infoType {
        case 3: .boolean(true) // hard_return: we store whole lines
        case 4: .boolean(line.kind == .note)
        case 5: .boolean(line.kind == .userInput)
        default: .boolean(false) // 6 log / 7 bookmark / 8 horizontal-rule — not modelled
        }
    }

    /// Style run text + byte geometry (infotypes 1 text, 2 byte length, 3
    /// 1-indexed byte start column).
    private static func styleText(_ text: String, _ run: StyledRun, _ infoType: Int) -> LuaValue {
        let slice = byteSlice(of: text, utf16Range: run.utf16Range)
        switch infoType {
        case 1: return .string(slice?.text ?? "")
        case 2: return .number(Double((slice?.text ?? "").utf8.count))
        default: return .number(Double((slice?.byteStart ?? 0) + 1)) // 3
        }
    }

    /// Style action fields (infotypes 4 action-type, 5 action, 6 hint, 7
    /// variable). Set-variable links aren't modelled (7 → "").
    private static func styleAction(_ link: LineLink?, _ infoType: Int) -> LuaValue {
        switch infoType {
        case 4: .number(Double(actionType(link)))
        case 5: .string(actionString(link))
        case 6: .string(link?.hint ?? "")
        default: .string("") // 7
        }
    }

    /// Style boolean flags (infotypes 8–13). changed/start-tag aren't modelled.
    private static func styleFlag(_ style: StyleAttributes, _ infoType: Int) -> LuaValue {
        switch infoType {
        case 8: .boolean(style.bold)
        case 9: .boolean(style.underline)
        case 10: .boolean(style.italic) // MUSHclient BLINK ≙ italic
        case 11: .boolean(style.reverse)
        default: .boolean(false) // 12 changed / 13 start-tag — not modelled
        }
    }

    private static func colourref(_ color: ANSIColor?, fallback: Int) -> Int {
        color.map { MUSHColour.int(for: $0) } ?? fallback
    }

    private static func actionType(_ link: LineLink?) -> Int {
        switch link?.action {
        case .openURL: 2 // hyperlink
        case .sendCommand: 1 // send to MUD
        case nil: 0 // no action
        }
    }

    private static func actionString(_ link: LineLink?) -> String {
        switch link?.action {
        case .openURL(let url): url
        case .sendCommand(let command): command
        case nil: ""
        }
    }

    /// The substring covered by a UTF-16 run range plus its UTF-8 byte offset
    /// from the line start (MUSHclient style columns/lengths are byte counts).
    private static func byteSlice(
        of text: String,
        utf16Range: Range<Int>
    ) -> (text: String, byteStart: Int)? {
        let utf16 = text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: utf16Range.lowerBound, limitedBy: utf16.endIndex)
        let upper = utf16.index(utf16.startIndex, offsetBy: utf16Range.upperBound, limitedBy: utf16.endIndex)
        guard let lower, let upper,
              let start = lower.samePosition(in: text),
              let end = upper.samePosition(in: text)
        else { return nil }
        return (String(text[start ..< end]), text[text.startIndex ..< start].utf8.count)
    }
}
