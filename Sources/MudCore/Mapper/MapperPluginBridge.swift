import Foundation

/// One plugin broadcast the mapper emits (`BroadcastPlugin(id, text)` in
/// MUSHclient). The text is a Lua assignment a listener can `loadstring`.
public struct MapperBroadcast: Sendable, Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// The result of a `CallPlugin(<mapper>, function, …)` dispatched to the
/// native mapper: any synchronous return `results` (MUSHclient's CallPlugin
/// returns trailing values) plus `broadcasts` to deliver asynchronously to
/// every plugin's `OnPluginBroadcast` (e.g. the 500/501 path results).
public struct MapperCallResult: Sendable, Equatable {
    public var results: [String]
    public var broadcasts: [MapperBroadcast]

    public init(results: [String] = [], broadcasts: [MapperBroadcast] = []) {
        self.results = results
        self.broadcasts = broadcasts
    }
}

/// Serialises path-find results into the exact `found_paths`/`unfound_paths`
/// Lua literals the Aardwolf mapper broadcasts (ids 500/501), so existing
/// listener plugins parse them unchanged. A faithful, pure port of
/// `aardmapper.lua`'s `full_find` broadcast payloads (`serialize.save_simple`).
public enum MapperPluginBridge {
    /// Broadcast id for "found paths" (a `{[uid] = {path=…, reason=…}}` map).
    public static let foundPathsBroadcast = 500
    /// Broadcast id for "unfound paths" (a `{ {uid=…, reason=…} }` list).
    public static let unfoundPathsBroadcast = 501

    /// A resolved target: a destination uid, an optional opaque `reason`
    /// (passed through to the broadcast), and the route (`nil` = no path).
    public struct Target: Sendable, Equatable {
        public let uid: String
        public let reason: String?
        public let path: [PathStep]?

        public init(uid: String, reason: String?, path: [PathStep]?) {
            self.uid = uid
            self.reason = reason
            self.path = path
        }
    }

    /// Build the `found_paths`/`unfound_paths` broadcast pair for `targets`.
    public static func broadcasts(for targets: [Target]) -> [MapperBroadcast] {
        [
            MapperBroadcast(id: foundPathsBroadcast, text: foundPaths(targets)),
            MapperBroadcast(id: unfoundPathsBroadcast, text: unfoundPaths(targets))
        ]
    }

    /// `found_paths = { ["uid"] = { path = { {dir="n", uid="2"}, … }, reason = … } }`.
    static func foundPaths(_ targets: [Target]) -> String {
        let entries = targets.compactMap { target -> String? in
            guard let path = target.path else { return nil }
            let steps = path
                .map { #"{ dir = \#(quote($0.dir)), uid = \#(quote($0.uid)) }"# }
                .joined(separator: ", ")
            let reason = target.reason.map { ", reason = \(quote($0))" } ?? ""
            return "[\(quote(target.uid))] = { path = { \(steps) }\(reason) }"
        }
        return "found_paths = { \(entries.joined(separator: ", ")) }"
    }

    /// `unfound_paths = { { uid = "9", reason = … }, … }`.
    static func unfoundPaths(_ targets: [Target]) -> String {
        let entries = targets.compactMap { target -> String? in
            guard target.path == nil else { return nil }
            let reason = target.reason.map { ", reason = \(quote($0))" } ?? ""
            return "{ uid = \(quote(target.uid))\(reason) }"
        }
        return "unfound_paths = { \(entries.joined(separator: ", ")) }"
    }

    /// A double-quoted Lua string literal (escapes `\` and `"`).
    private static func quote(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
