import Foundation

/// The one-time upgrade of a version-1 `soundpack.json` (D-127).
///
/// Version 1 (≤ 0.8.x) had no `version` key and one `file` per event. Version
/// 2 turns that into a one-file `files` list; everything else carries over
/// unchanged. ``SettingsFileBacked/load(from:)`` writes the result back, so a
/// file is converted once, by whichever reader loads it first (the plugin or
/// Settings ▸ Audio).
///
/// Kept in its own file so it can be deleted once no version-1 file can
/// remain.
public extension SoundpackConfig {
    static func migrated(_ data: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["version"] == nil
        else { return nil }
        if var events = object["events"] as? [String: Any] {
            for (name, value) in events {
                guard var entry = value as? [String: Any],
                      let file = entry.removeValue(forKey: "file") as? String
                else { continue }
                entry["files"] = [file]
                events[name] = entry
            }
            object["events"] = events
        }
        object["version"] = currentVersion
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
