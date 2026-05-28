import Foundation

/// Writes a user-facing session log: each finalized scrollback ``Line`` is
/// appended to a file as plain text or HTML (via ``SessionLogFormatter``). One
/// logger per connect (the natural session boundary). Distinct from the binary
/// replay (`SessionRecorder`) and the debug transcript (`SessionTranscript`) —
/// this is the readable, colour-preserving record for the *player*.
///
/// An `actor` so appends from the scrollback-drain task are serialized; file
/// I/O failures degrade gracefully (the logger goes inert rather than throwing
/// into the session).
public actor SessionLogger {
    private let handle: FileHandle
    private let format: SessionLogFormat
    private let palette: ColorPalette
    private var closed = false

    /// Open a log at `url` (creating parent directories). Returns `nil` if the
    /// file can't be created. Writes the HTML header up front for `.html`.
    public init?(url: URL, format: SessionLogFormat, palette: ColorPalette = .xtermDefault) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { return nil }
        self.handle = handle
        self.format = format
        self.palette = palette
        if format == .html, let data = SessionLogFormatter.htmlHeader(palette: palette).data(using: .utf8) {
            try? handle.write(contentsOf: data) // direct (init can't call the isolated write)
        }
    }

    /// Append one line to the log (a no-op once closed).
    public func append(_ line: Line) {
        guard !closed else { return }
        switch format {
        case .text: write(SessionLogFormatter.text(line) + "\n")
        case .html: write(SessionLogFormatter.htmlLine(line, palette: palette) + "\n")
        }
    }

    /// Finish the log (HTML footer + close the handle). Idempotent.
    public func close() {
        guard !closed else { return }
        closed = true
        if format == .html { write(SessionLogFormatter.htmlFooter) }
        try? handle.close()
    }

    private func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
