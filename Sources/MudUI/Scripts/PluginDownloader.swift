#if os(macOS)
    import Foundation

    /// Downloads a plugin from a URL into a staging directory — the "From a URL"
    /// half of Add Plugin…. Handles both a single raw file (e.g. a
    /// `raw.githubusercontent.com/.../foo.xml`) and a zip (a release asset or a
    /// GitHub repo/branch codeload zip), detected by content rather than URL
    /// extension. Generalises the Search-and-Destroy installer's download+extract.
    ///
    /// macOS only (uses `/usr/bin/ditto` for extraction); the call site is the
    /// Plugins window, which is macOS-only today.
    public enum PluginDownloader {
        public enum DownloadError: LocalizedError {
            case http(Int)
            case download(String)
            case extract(String)
            case empty

            public var errorDescription: String? {
                switch self {
                case .http(let code): "Download failed: HTTP \(code)."
                case .download(let detail): "Download failed: \(detail)"
                case .extract(let detail): "Couldn't unpack the download: \(detail)"
                case .empty: "The download was empty."
                }
            }
        }

        /// Download `url` into `destination` (created fresh). A zip is extracted;
        /// any other file is saved under its URL's last path component (or
        /// `plugin.xml`). The caller then resolves the plugin `.xml` within.
        public static func download(
            from url: URL,
            into destination: URL,
            session: URLSession = .shared,
            fileManager: FileManager = .default
        ) async throws {
            let tempFile: URL
            let response: URLResponse
            do {
                (tempFile, response) = try await session.download(from: url)
            } catch {
                throw DownloadError.download(error.localizedDescription)
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw DownloadError.http(http.statusCode)
            }

            try? fileManager.removeItem(at: destination)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

            if isZip(tempFile) {
                try extract(zip: tempFile, into: destination)
            } else {
                let name = url.lastPathComponent.isEmpty || !url.lastPathComponent.contains(".")
                    ? "plugin.xml" : url.lastPathComponent
                do {
                    try fileManager.copyItem(at: tempFile, to: destination.appendingPathComponent(name))
                } catch {
                    throw DownloadError.download(error.localizedDescription)
                }
            }
            let contents = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
            guard !contents.isEmpty else { throw DownloadError.empty }
        }

        /// Whether `file` begins with the PKZip magic (`PK\x03\x04`).
        static func isZip(_ file: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            let magic = handle.readData(ofLength: 4)
            return magic.elementsEqual([0x50, 0x4B, 0x03, 0x04])
        }

        /// Extract a zip into `dir` using `ditto` (reads standard PKZip archives).
        static func extract(zip: URL, into dir: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, dir.path]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
            } catch {
                throw DownloadError.extract(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
                ) ?? "ditto exited \(process.terminationStatus)"
                throw DownloadError.extract(message)
            }
        }
    }
#endif
