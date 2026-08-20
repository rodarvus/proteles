import Foundation

/// Applies the simple `{start, stop, text, label}` link tables accepted by the
/// reference Communication Log's `storeFromOutside`. Positions are 1-based and
/// inclusive, matching `text_rect.lua`.
enum ExternalCaptureLinks {
    static func applying(_ json: String?, lineIndex: Int, to line: Line) -> Line {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return line }
        let selected = selectedLinks(from: object, lineIndex: lineIndex)
        let links = dictionaries(in: selected)
        guard !links.isEmpty else { return line }
        var runs = line.runs
        for link in links {
            guard let start = number(link["start"]),
                  let stop = number(link["stop"]),
                  start >= 1,
                  stop >= start,
                  stop <= line.text.utf16.count,
                  let rawAction = link["text"] as? String
            else { continue }
            let label = link["label"] as? String
            // Some package windows serialize a Lua callback in `text` and put
            // its user-intended command in `label`; never send Lua source to
            // the game when the direct command is available.
            let action = rawAction.contains("(") && label != nil ? label! : rawAction
            runs.append(StyledRun(
                utf16Range: (start - 1)..<stop,
                style: style(at: start - 1, in: line),
                link: LineLink(actionString: action, hint: label)
            ))
        }
        return Line(
            id: line.id, timestamp: line.timestamp, text: line.text, runs: runs
        )
    }

    private static func selectedLinks(from object: Any, lineIndex: Int) -> Any {
        guard let lines = object as? [Any],
              lines.indices.contains(lineIndex),
              lines[lineIndex] is [Any]
        else { return object }
        return lines[lineIndex]
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any], dictionary["start"] != nil {
            return [dictionary]
        }
        if let array = value as? [Any] {
            return array.flatMap(dictionaries)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.flatMap(dictionaries)
        }
        return []
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    private static func style(at offset: Int, in line: Line) -> StyleAttributes {
        line.runs.first { $0.utf16Range.contains(offset) }?.style ?? .default
    }
}
