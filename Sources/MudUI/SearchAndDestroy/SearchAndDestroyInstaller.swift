#if os(macOS)
    import Foundation
    import MudCore

    /// Downloads + installs the Search-and-Destroy plugin (by Crowley) on the
    /// user's request. S&D is **not bundled** with Proteles; this fetches its
    /// Lua from the maintainer's release and extracts it into
    /// ``SearchAndDestroyAssets/defaultInstallDirectory`` so the S&D host can
    /// load it (no app restart needed — the caller re-attaches the host).
    public enum SearchAndDestroyInstaller {
        /// The release asset Proteles installs (see the repo's README/NOTICES).
        public static let downloadURL = URL(
            string: "https://github.com/rodarvus/Search-and-Destroy-crowley"
                + "/releases/latest/download/proteles-snd.zip"
        )!

        public enum InstallError: LocalizedError {
            case noInstallDirectory
            case download(String)
            case extract(String)
            case incomplete

            public var errorDescription: String? {
                switch self {
                case .noInstallDirectory: "Couldn't locate the application support folder."
                case .download(let detail): "Download failed: \(detail)"
                case .extract(let detail): "Couldn't unpack the download: \(detail)"
                case .incomplete: "The download didn't contain the expected plugin files."
                }
            }
        }

        /// Download the plugin archive and extract it into the install dir.
        /// Throws on network/extract failure or if the result is incomplete.
        public static func install(from url: URL = downloadURL) async throws {
            guard let dir = SearchAndDestroyAssets.defaultInstallDirectory else {
                throw InstallError.noInstallDirectory
            }
            let (tempZip, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw InstallError.download("HTTP \(http.statusCode)")
            }
            try extract(zip: tempZip, into: dir)
            guard SearchAndDestroyAssets.core != nil else { throw InstallError.incomplete }
        }

        /// Extract a flat plugin zip into `dir` (clean-replacing any prior
        /// install). Uses `ditto`, which reads standard PKZip archives.
        static func extract(zip: URL, into dir: URL) throws {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: dir)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, dir.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? "ditto exited \(process.terminationStatus)"
                throw InstallError.extract(message)
            }
        }
    }
#endif
