import Foundation

/// The human `.log` beside each recording, read as a stream of entries for
/// the scenario replays (`ScenarioReplayTests`). The `.jsonl` holds inbound
/// bytes only; the log also has what the client sent (`SEND`), what the
/// player typed (`INPUT`) and the client's own notes (`NOTE`), interleaved
/// in order, which is what a replay of client behaviour needs.
///
/// A line is `<timestamp> <KIND> <body>`, the kind padded to five columns:
/// `2026-10-17T09:35:06.187+01:00 RECV  You can't run while sitting.`
/// The file is memory-mapped and scanned once; only the kinds asked for are
/// decoded, so the 15 GB of logs cost minutes, not a full parse each.
enum RecordingLog {
    enum Kind: String, CaseIterable {
        case recv = "RECV"
        case send = "SEND"
        case input = "INPUT"
        case note = "NOTE"
        case gmcp = "GMCP"
        case gag = "GAG"
    }

    struct Entry {
        /// Seconds since 1970, from the line's own timestamp (any offset).
        let time: Double
        let kind: Kind
        let body: String

        var date: Date {
            Date(timeIntervalSince1970: time)
        }
    }

    /// The kinds' five-column fields, as bytes.
    fileprivate static let fields: [(bytes: [UInt8], kind: Kind)] = Kind.allCases.map { kind in
        (Array(kind.rawValue.padding(toLength: 5, withPad: " ", startingAt: 0).utf8), kind)
    }

    /// Every entry of `kinds` in the log at `url`, in order. `visit` returns
    /// false to stop early.
    static func forEach(
        _ url: URL,
        kinds: Set<Kind>,
        _ visit: (Entry) throws -> Bool
    ) throws {
        var reader = try Reader(url, kinds: kinds)
        while let entry = reader.next() {
            guard try visit(entry) else { return }
        }
    }

    /// The log's entries one at a time, for a caller that awaits between
    /// them. Lines that aren't entries (a body's own line break, a truncated
    /// last line) are skipped.
    struct Reader {
        private let data: Data
        private let wanted: [(bytes: [UInt8], kind: Kind)]
        private var offset = 0

        init(_ url: URL, kinds: Set<Kind>) throws {
            data = try Data(contentsOf: url, options: .alwaysMapped)
            wanted = RecordingLog.fields.filter { kinds.contains($0.kind) }
        }

        mutating func next() -> Entry? {
            let (wanted, start) = (wanted, offset)
            let found: (Entry?, Int) = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                var lineStart = start
                while lineStart < bytes.count {
                    var end = lineStart
                    while end < bytes.count, bytes[end] != 0x0A {
                        end += 1
                    }
                    if let entry = RecordingLog
                        .parse(bytes, lineStart, end, wanted) { return (entry, end + 1) }
                    lineStart = end + 1
                }
                return (nil, bytes.count)
            }
            offset = found.1
            return found.0
        }
    }

    fileprivate static func parse(
        _ bytes: UnsafeBufferPointer<UInt8>,
        _ start: Int,
        _ end: Int,
        _ wanted: [(bytes: [UInt8], kind: Kind)]
    ) -> Entry? {
        // The timestamp runs to the first space.
        var space = start
        while space < end, bytes[space] != 0x20 {
            space += 1
        }
        let fieldStart = space + 1
        let bodyStart = fieldStart + 6
        guard bodyStart <= end, let time = timestamp(bytes, start, space),
              let kind = wanted.first(where: { field in
                  field.bytes.indices.allSatisfy { bytes[fieldStart + $0] == field.bytes[$0] }
              })?.kind else { return nil }
        var bodyEnd = end
        if bodyEnd > bodyStart, bytes[bodyEnd - 1] == 0x0D { bodyEnd -= 1 }
        let body = String(decoding: UnsafeBufferPointer(rebasing: bytes[bodyStart..<bodyEnd]), as: UTF8.self)
        return Entry(time: time, kind: kind, body: body)
    }

    /// `2026-10-30T07:10:26.411Z` or `2026-08-21T13:14:09.488+01:00`, parsed
    /// by hand: `ISO8601DateFormatter` would cost more than the rest of the
    /// line's handling.
    static func timestamp(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> Double? {
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= end else { return nil }
            var value = 0
            for index in from..<(from + count) {
                let digit = Int(bytes[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard end - start >= 20, bytes[start + 10] == UInt8(ascii: "T"),
              let year = number(start, 4), let month = number(start + 5, 2), let day = number(start + 8, 2),
              let hour = number(start + 11, 2), let minute = number(start + 14, 2),
              let second = number(start + 17, 2)
        else { return nil }
        var cursor = start + 19
        var fraction = 0.0
        if cursor < end, bytes[cursor] == UInt8(ascii: ".") {
            cursor += 1
            var (digits, scale) = (0, 1)
            while cursor < end, let digit = number(cursor, 1) {
                digits = digits * 10 + digit
                scale *= 10
                cursor += 1
            }
            fraction = Double(digits) / Double(scale)
        }
        var offset = 0
        if cursor < end, bytes[cursor] == UInt8(ascii: "+") || bytes[cursor] == UInt8(ascii: "-") {
            guard let hours = number(cursor + 1, 2), let minutes = number(cursor + 4, 2) else { return nil }
            offset = (hours * 3600 + minutes * 60) * (bytes[cursor] == UInt8(ascii: "-") ? -1 : 1)
        }
        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offset
        return Double(seconds) + fraction
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Hinnant).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Recordings with a log, oldest first; `PROTELES_SCENARIO_SESSIONS`
    /// (comma-separated substrings) narrows them for a quick run.
    static func corpusLogs(in directory: URL = CorpusReplay.corpusDirectory) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        let filter = ProcessInfo.processInfo.environment["PROTELES_SCENARIO_SESSIONS"]?
            .split(separator: ",").map(String.init) ?? []
        return urls.filter { $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix("session-") }
            .filter { url in filter.isEmpty || filter.contains { url.lastPathComponent.contains($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
