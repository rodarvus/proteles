import Foundation
@testable import MudCore

/// When each whole-room `consider` was sent, from the `.log` beside a
/// recording (S0b item 2, #84). The `.jsonl` holds inbound bytes only, but
/// the state model opens its consider window on the *outbound* command
/// (`SessionController.sendLine`), so the replay reads the log's `SEND`
/// lines and opens the window at the same point in the byte stream.
extension CorpusReplay {
    /// Send times of whole-room considers, oldest first; empty when the log
    /// is missing. The log is memory-mapped and searched for its `SEND`
    /// marker, so the 14 GB of logs cost seconds, not a full parse.
    static func roomConsiderSendTimes(forRecording url: URL) -> [Date] {
        let log = url.deletingPathExtension().appendingPathExtension("log")
        guard let data = try? Data(contentsOf: log, options: .alwaysMapped) else { return [] }
        let marker = Data(" SEND  con".utf8)
        var times: [Date] = []
        var searchStart = data.startIndex
        while let hit = data.range(of: marker, in: searchStart..<data.endIndex) {
            searchStart = hit.upperBound
            let lineStart = data[..<hit.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data
                .startIndex
            let lineEnd = data[hit.upperBound...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let commandStart = hit.lowerBound + " SEND  ".utf8.count
            guard let command = String(data: data[commandStart..<lineEnd], encoding: .utf8),
                  ConsiderWindow.isRoomConsider(command),
                  let stamp = String(data: data[lineStart..<hit.lowerBound], encoding: .utf8),
                  // `SEND` straight after the timestamp: not the words inside a received line.
                  !stamp.contains(" "),
                  let date = parseLogTimestamp(stamp)
            else { continue }
            times.append(date)
        }
        return times
    }

    /// `2026-10-30T07:10:26.411Z` or, in older logs, `2026-08-21T13:14:09.488+01:00`.
    private static func parseLogTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
