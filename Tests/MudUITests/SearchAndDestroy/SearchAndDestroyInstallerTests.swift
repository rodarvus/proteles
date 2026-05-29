#if os(macOS)
    import Foundation
    import MudCore
    @testable import MudUI
    import Testing

    @Suite("SearchAndDestroyInstaller — extract")
    struct SearchAndDestroyInstallerTests {
        @Test("Extracting a flat plugin zip installs the files (isInstalled flips)")
        func extractsFlatZip() throws {
            let fileManager = FileManager.default
            let tmp = fileManager.temporaryDirectory
                .appendingPathComponent("snd-install-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: tmp) }

            // Build a flat zip (files at root) like the release asset.
            let core = tmp.appendingPathComponent("core.lua")
            let constants = tmp.appendingPathComponent("constants.lua")
            try "-- core".write(to: core, atomically: true, encoding: .utf8)
            try "-- constants".write(to: constants, atomically: true, encoding: .utf8)
            let zip = tmp.appendingPathComponent("snd.zip")
            let packer = Process()
            packer.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            packer.arguments = ["-j", "-q", zip.path, core.path, constants.path]
            try packer.run()
            packer.waitUntilExit()
            #expect(packer.terminationStatus == 0)

            // Extract into a fresh install dir.
            let install = tmp.appendingPathComponent("installed", isDirectory: true)
            try SearchAndDestroyInstaller.extract(zip: zip, into: install)

            #expect(fileManager.fileExists(atPath: install.appendingPathComponent("core.lua").path))
            #expect(fileManager.fileExists(atPath: install.appendingPathComponent("constants.lua").path))

            // Reading the asset accessor at the install dir reports installed.
            // Use the `in:` accessors (not the shared global) so this stays
            // hermetic under `--parallel`.
            #expect(SearchAndDestroyAssets.isInstalled(in: install))
            #expect(SearchAndDestroyAssets.core(in: install) == "-- core")
        }
    }
#endif
