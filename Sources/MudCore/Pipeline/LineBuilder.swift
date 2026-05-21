import Foundation

/// Converts the ``ANSIEvent`` stream from ``ANSIParser`` into ``Line``
/// records suitable for ``ScrollbackStore``.
///
/// The builder accumulates text (with styling) until a ``ANSIEvent/lineFeed``
/// arrives, then emits a finalised ``Line``. Style state persists across
/// line boundaries — the ANSI parser drives that, not us. Lines are
/// emitted with ``LineID(0)`` as a placeholder; ``ScrollbackStore`` mints
/// the real monotonic ID on append.
///
/// Run-emission policy: runs are produced **only for non-default styles**.
/// Default-styled spans have no entry in ``Line/runs``; the renderer
/// applies its default attributes to any range not covered by an
/// explicit run. This keeps plain-ASCII lines (the common case) cheap.
///
/// ``ANSIEvent/carriageReturn``, ``ANSIEvent/bell``,
/// ``ANSIEvent/backspace``, ``ANSIEvent/tab``,
/// ``ANSIEvent/otherControl(_:)`` and
/// ``ANSIEvent/unhandledCSI(final:parameters:)`` do not contribute to
/// line content in Phase 1 and are silently discarded. CR is *not*
/// interpreted as "go to start of line"; Aardwolf emits CRLF and we let
/// the LF do the work.
public struct LineBuilder: Sendable {
    private var text: String = ""
    private var runs: [StyledRun] = []
    private var openRunStart: Int = 0
    private var currentStyle: StyleAttributes = .default

    public init() {}

    /// Text accumulated for the line currently being built but not yet
    /// emitted (no terminating `lineFeed` seen). Empty between lines.
    ///
    /// MUD prompts (e.g. Aardwolf's `"What be thy name, adventurer? "`)
    /// arrive without a trailing newline and therefore sit here rather
    /// than being emitted as a ``Line`` — autologin prompt-matching reads
    /// this so it can react before the line is finalised.
    public var pendingText: String {
        text
    }

    /// Consume one ANSI event. Emits zero or one ``Line`` via the
    /// closure (exactly one on ``ANSIEvent/lineFeed`` if there is
    /// content or if the previous event ended a line).
    public mutating func consume(
        _ event: ANSIEvent,
        emit: (Line) -> Void
    ) {
        switch event {
        case .text(let string, let style):
            appendText(string, style: style)
        case .lineFeed:
            finalizeLine(emit: emit)
        case .carriageReturn,
             .bell,
             .backspace,
             .tab,
             .otherControl,
             .unhandledCSI:
            break
        }
    }

    /// Emit any in-progress line. Use at end-of-stream (e.g. before
    /// disconnect) to flush a partial line that arrived without a
    /// trailing LF.
    public mutating func flush(emit: (Line) -> Void) {
        if !text.isEmpty {
            finalizeLine(emit: emit)
        }
    }

    /// Reset all state to initial — including the persisted style. Call
    /// between connections.
    public mutating func reset() {
        text = ""
        runs = []
        openRunStart = 0
        currentStyle = .default
    }

    // MARK: - Private

    private mutating func appendText(
        _ string: String,
        style: StyleAttributes
    ) {
        if style != currentStyle {
            closeCurrentRun()
            openRunStart = text.utf16.count
            currentStyle = style
        }
        text += string
    }

    private mutating func closeCurrentRun() {
        let endOffset = text.utf16.count
        guard openRunStart < endOffset else { return }
        guard !currentStyle.isDefault else { return }
        runs.append(StyledRun(
            utf16Range: openRunStart..<endOffset,
            style: currentStyle
        ))
    }

    private mutating func finalizeLine(emit: (Line) -> Void) {
        closeCurrentRun()
        let line = Line(
            id: LineID(0),
            timestamp: Date(),
            text: text,
            runs: runs
        )
        emit(line)
        text = ""
        runs = []
        openRunStart = 0
        // currentStyle persists across lines deliberately.
    }
}
