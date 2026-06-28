import Foundation

/// The mapper's CallPlugin surface: lets third-party plugins reach the native
/// mapper through its well-known MUSHclient plugin id (see
/// ``MapperPluginBridge`` for the broadcast serialisation).
public extension Mapper {
    /// The mapper's well-known MUSHclient plugin id — the one third-party
    /// plugins target with `CallPlugin(...)` / listen to broadcasts from.
    static let pluginID = "b6eae87ccedd84f510b74714"

    /// Handle a `CallPlugin(<mapper>, function, args…)` routed to the native
    /// mapper. Returns synchronous `results` plus any `broadcasts` to deliver
    /// to every plugin's `OnPluginBroadcast` (e.g. 500/501 path results).
    /// Unknown functions return an empty result (graceful, like a no-op call).
    func handlePluginCall(_ function: String, args: [String]) -> MapperCallResult {
        switch function.lowercased() {
        case "get_current_room":
            return MapperCallResult(results: [currentRoomUID ?? ""])
        case "getkeyword":
            return MapperCallResult(results: [keywordMatches(args.first ?? "")])
        case "override_continents":
            return MapperCallResult() // accepted; we have no continent bigmap
        case "find", "do_find":
            return MapperCallResult(broadcasts: MapperPluginBridge.broadcasts(for: resolveTargets(args)))
        case "findpath":
            if args.count >= 2 {
                return resolvePath(from: args[0], to: args[1], args: args)
            }
            return MapperCallResult(broadcasts: MapperPluginBridge.broadcasts(for: resolveTargets(args)))
        default:
            return MapperCallResult()
        }
    }

    /// Area uids whose key or name matches `query` (case-insensitive,
    /// comma-joined) — mirrors the mapper's `getkeyword`.
    private func keywordMatches(_ query: String) -> String {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return "" }
        return graph.areas.values
            .filter { $0.uid.lowercased().contains(needle) || ($0.name ?? "").lowercased().contains(needle) }
            .map(\.uid)
            .sorted()
            .joined(separator: ",")
    }

    /// Route from the current room to each target uid in `args`, producing
    /// resolved ``MapperPluginBridge/Target`` records (path or unfound).
    private func resolveTargets(_ args: [String]) -> [MapperPluginBridge.Target] {
        let uids = args.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init) }
        guard let src = currentRoomUID else {
            return uids.map { .init(uid: $0, reason: nil, path: nil) }
        }
        let finder = Pathfinder(graph: graph)
        let options = Pathfinder.Options(level: level, tier: tier)
        return uids.map { uid in
            MapperPluginBridge.Target(
                uid: uid,
                reason: nil,
                path: finder.path(from: src, to: uid, options: options)
            )
        }
    }

    /// Reference-compatible `findpath(src, dst, noportals, norecalls)`: path
    /// from an arbitrary source, broadcasting id 502 when a path is found.
    private func resolvePath(
        from source: String,
        to destination: String,
        args: [String]
    ) -> MapperCallResult {
        guard source != destination else { return MapperCallResult(results: ["0"]) }
        let noPortals = Self.luaBool(args.dropFirst(2).first)
        let noRecalls = Self.luaBool(args.dropFirst(3).first)
        let options = Pathfinder.Options(
            level: level,
            tier: tier,
            allowPortals: !noPortals,
            allowRecalls: !noRecalls
        )
        guard let path = Pathfinder(graph: graph).path(from: source, to: destination, options: options) else {
            return MapperCallResult()
        }
        return MapperCallResult(
            results: [String(path.count)],
            broadcasts: [MapperPluginBridge.pathBroadcast(path)]
        )
    }

    private static func luaBool(_ value: String?) -> Bool {
        switch value?.lowercased() {
        case "true", "1", "yes", "y": true
        default: false
        }
    }
}
