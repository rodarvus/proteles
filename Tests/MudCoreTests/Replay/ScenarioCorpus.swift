#if os(macOS)
    import Foundation
    @testable import MudCore

    /// What the corpus scenario run needs around the rigs: the opt-in switch,
    /// the Consider pass spread over the cores, and copies of the live maps.
    /// macOS only: the corpus and the maps live on the Mac (and `Process`
    /// does).
    enum ScenarioCorpus {
        /// Opt-in, like the corpus replay: hours of logs never ride inside the
        /// default `swift test`.
        static var isEnabled: Bool {
            ProcessInfo.processInfo.environment["PROTELES_SCENARIOS"] != nil
        }

        /// `PROTELES_SCENARIOS=consider` or `=walks` runs one pass alone.
        static func runs(_ pass: String) -> Bool {
            let value = ProcessInfo.processInfo.environment["PROTELES_SCENARIOS"] ?? ""
            return value == pass || !["consider", "walks"].contains(value)
        }

        /// The Consider rig is pure, so sessions replay side by side.
        static func considerAll(_ logs: [URL]) async throws -> [ConsiderScenarioReplay.Result] {
            let width = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
            return try await withThrowingTaskGroup(of: (Int, ConsiderScenarioReplay.Result).self) { group in
                var results: [ConsiderScenarioReplay.Result?] = Array(repeating: nil, count: logs.count)
                var next = 0
                func submit() {
                    guard next < logs.count else { return }
                    let (index, url) = (next, logs[next])
                    next += 1
                    group.addTask { try (index, ConsiderScenarioReplay.replay(url)) }
                }
                for _ in 0..<width {
                    submit()
                }
                while let (index, result) = try await group.next() {
                    results[index] = result
                    print("scenario: consider \(result.name) violations=\(result.audit.violations.count)")
                    submit()
                }
                return results.compactMap(\.self)
            }
        }

        /// The walk rig, a stripe of sessions per core, each stripe with its
        /// own copies of the maps (the replay writes rooms to them).
        static func walkAll(_ logs: [URL]) async throws -> [WalkScenarioReplay.Result] {
            let width = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
            return try await withThrowingTaskGroup(of: [(Int, WalkScenarioReplay.Result)].self) { group in
                for stripe in 0..<width {
                    group.addTask {
                        let maps = try MapCopies()
                        defer { maps.remove() }
                        // One mapper per character per stripe: a second store
                        // over the same copy can't take its WAL lock.
                        var mappers: [URL?: Mapper] = [:]
                        var out: [(Int, WalkScenarioReplay.Result)] = []
                        for index in stride(from: stripe, to: logs.count, by: width) {
                            let url = logs[index]
                            var result: WalkScenarioReplay.Result
                            do {
                                let personal = try maps.personal(for: url)
                                let mapper = try mappers[personal] ?? Mapper(
                                    store: MapperStore(url: maps.shared, personalURL: personal)
                                )
                                mappers[personal] = mapper
                                result = try await WalkScenarioReplay.replay(url, mapper: mapper)
                            } catch {
                                result = .init(name: url.deletingPathExtension().lastPathComponent)
                                result.violations = ["\(result.name) replay failed: \(error)"]
                            }
                            let windows = result.windows.values.reduce(0, +)
                            print("scenario: walks \(result.name) windows=\(windows) "
                                + "violations=\(result.violations.count)")
                            for trace in result.traces.prefix(3) {
                                print("scenario:   \(trace)")
                            }
                            out.append((index, result))
                        }
                        return out
                    }
                }
                var results: [(Int, WalkScenarioReplay.Result)] = []
                for try await stripe in group {
                    results += stripe
                }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }

        /// Copies of the live map (`sqlite3 .backup`, so a running app's WAL is
        /// included and nothing of the user's is written), and of each
        /// character's overlay as a session needs it. The replay writes rooms to
        /// the copies, as the session would.
        final class MapCopies {
            let directory: URL
            let shared: URL
            private var overlays: [String: URL?] = [:]
            private static let databases = CorpusReplay.realHome
                .appendingPathComponent("Documents/Proteles/Databases")

            init() throws {
                directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("proteles-scenarios-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                shared = directory.appendingPathComponent("Aardwolf.db")
                try Self.backup(Self.databases.appendingPathComponent("Aardwolf.db"), to: shared)
            }

            /// The overlay of the character the log played (its first
            /// `char.base` name), or nil when there is none.
            func personal(for log: URL) throws -> URL? {
                let name = try Self.character(in: log)?.lowercased() ?? ""
                if let cached = overlays[name] { return cached }
                let source = Self.databases.appendingPathComponent("\(name)/Aardwolf-personal.db")
                var copy: URL?
                if !name.isEmpty, FileManager.default.fileExists(atPath: source.path) {
                    let url = directory.appendingPathComponent("\(name)-personal.db")
                    try Self.backup(source, to: url)
                    copy = url
                }
                overlays[name] = copy
                return copy
            }

            func remove() {
                try? FileManager.default.removeItem(at: directory)
            }

            private static func character(in log: URL) throws -> String? {
                var reader = try RecordingLog.Reader(log, kinds: [.gmcp])
                while let entry = reader.next() {
                    guard entry.body.hasPrefix("char.base ") else { continue }
                    let json = Data(entry.body.dropFirst("char.base ".count).utf8)
                    let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                    return object?["name"] as? String
                }
                return nil
            }

            /// Stripes start together, so a read can meet another's lock:
            /// tried three times.
            private static func backup(_ source: URL, to destination: URL) throws {
                for attempt in 1...3 {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                    process.arguments = ["-readonly", source.path, ".backup '\(destination.path)'"]
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 { return }
                    if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
                }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path])
            }
        }
    }
#endif
