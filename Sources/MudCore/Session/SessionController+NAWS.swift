import Foundation

/// NAWS — Negotiate About Window Size (RFC 1073, telnet option 31). The pipeline
/// agrees to `DO NAWS` with `WILL NAWS`; this sends the dimensions: an initial
/// `SB NAWS` once negotiated, then a fresh one whenever the character grid
/// changes. Aardwolf may treat the size as informational, but reporting it is
/// the standard, harmless thing to do (matches MUSHclient/Mudlet).
public extension SessionController {
    /// The app reports the output view's character grid (from the monospaced
    /// font's cell metrics) here. Records it and, if NAWS is live and the size
    /// changed, sends an updated `SB NAWS`.
    func setTerminalSize(columns: Int, rows: Int) async {
        let cols = max(1, columns)
        let rowCount = max(1, rows)
        guard cols != lastTerminalColumns || rowCount != lastTerminalRows else { return }
        lastTerminalColumns = cols
        lastTerminalRows = rowCount
        if nawsEnabled { try? await sendRaw(Self.nawsPayload(columns: cols, rows: rowCount)) }
    }

    /// The server negotiated NAWS (`DO NAWS`). Remember it and send the current
    /// size straight away (once we have one — otherwise the first
    /// ``setTerminalSize(columns:rows:)`` will).
    func enableNAWS() async {
        nawsEnabled = true
        guard lastTerminalColumns > 0, lastTerminalRows > 0 else { return }
        try? await sendRaw(Self.nawsPayload(columns: lastTerminalColumns, rows: lastTerminalRows))
    }

    /// Build `IAC SB NAWS <16-bit cols> <16-bit rows> IAC SE` — 16-bit
    /// big-endian columns and rows, with any `0xFF` value byte doubled so the
    /// server can't mistake it for an `IAC`. Static + internal so the byte
    /// layout (and escaping) is unit-testable without a live connection.
    static func nawsPayload(columns: Int, rows: Int) -> [UInt8] {
        var payload: [UInt8] = [TelnetCommand.iac, TelnetCommand.sb, TelnetOption.naws]
        appendEscaped(UInt16(clamping: columns), to: &payload)
        appendEscaped(UInt16(clamping: rows), to: &payload)
        payload.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])
        return payload
    }

    private static func appendEscaped(_ value: UInt16, to payload: inout [UInt8]) {
        for byte in [UInt8(value >> 8), UInt8(value & 0xFF)] {
            payload.append(byte)
            if byte == TelnetCommand.iac { payload.append(TelnetCommand.iac) }
        }
    }
}
