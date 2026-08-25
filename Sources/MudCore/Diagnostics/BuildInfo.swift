import Foundation

/// Which build produced this session.
///
/// Recorded once per session in the transcript, **ungated** — it is one line,
/// and without it no performance comparison across recordings is valid.
///
/// That is not hypothetical. Every session before this existed reported
/// `"version": "0.8.8"` whether it was the notarized Release or a locally
/// installed Debug build, and Debug is **2.30x slower** through the line
/// classifier (34.2µs vs 14.9µs per line, measured). A Release baseline was
/// compared against Debug candidates for three days and the ~330ms difference
/// in kill-burst paint latency was attributed to a code change. It was the
/// build configuration.
///
/// See `docs/plans/BURST_INSTRUMENTATION_PROPOSAL.md` §1 and the Release-build
/// rule in CLAUDE.md.
public struct BuildInfo: Sendable, Equatable {
    /// `Debug` or `Release` — the field whose absence caused the misdiagnosis.
    /// Compile-time, so it cannot disagree with the binary it describes.
    public let configuration: String
    /// `CFBundleShortVersionString`, e.g. `0.8.8`.
    public let version: String
    /// `CFBundleVersion`, e.g. `56`. What Sparkle compares.
    public let build: String
    /// Short git SHA at build time, when the build stamped one.
    ///
    /// Deliberately preferred over bumping the build number per change:
    /// `CFBundleVersion` is what Sparkle compares, so a dev build outranking a
    /// published one is a real failure mode (it stranded `v0.5.0`), and a bumped
    /// number still would not distinguish Debug from Release.
    public let commit: String?
    /// Whether the working tree had uncommitted changes at build time. `nil`
    /// when the build did not stamp provenance.
    public let dirty: Bool?

    public init(
        configuration: String,
        version: String,
        build: String,
        commit: String? = nil,
        dirty: Bool? = nil
    ) {
        self.configuration = configuration
        self.version = version
        self.build = build
        self.commit = commit
        self.dirty = dirty
    }

    /// The compile-time configuration of the binary containing this code.
    public static var currentConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }

    /// Read from the main bundle, falling back to `?` for anything absent (a
    /// test host has no version keys, and a build that skipped the stamping
    /// script has no commit).
    public static func current(bundle: Bundle = .main) -> BuildInfo {
        func string(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        let commit = string("ProtelesGitCommit")
        return BuildInfo(
            configuration: currentConfiguration,
            version: string("CFBundleShortVersionString") ?? "?",
            build: string("CFBundleVersion") ?? "?",
            commit: commit,
            dirty: commit == nil ? nil : (string("ProtelesGitDirty") == "1")
        )
    }

    /// The transcript line, e.g.
    /// `0.8.8 (56) Release 43bd3dcd clean` — or `… (unstamped)` when the build
    /// carried no git provenance, which is itself worth seeing.
    public var transcriptLine: String {
        var parts = ["\(version) (\(build))", configuration]
        if let commit {
            parts.append(commit)
            parts.append(dirty == true ? "dirty" : "clean")
        } else {
            parts.append("(unstamped)")
        }
        return parts.joined(separator: " ")
    }
}
