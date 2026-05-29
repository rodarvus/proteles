#if os(macOS)
    import Foundation
    @testable import MudUI
    import Testing

    @Suite("PluginExporter")
    struct PluginExporterTests {
        @Test("export zips the plugin dir, excluding data/")
        func excludesData() throws {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString)", isDirectory: true)
            let plugin = root.appendingPathComponent("MyPlugin", isDirectory: true)
            try fm.createDirectory(
                at: plugin.appendingPathComponent("data/char", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("<muclient/>".utf8).write(to: plugin.appendingPathComponent("MyPlugin.xml"))
            try Data("db".utf8).write(to: plugin.appendingPathComponent("data/char/x.db"))
            defer { try? fm.removeItem(at: root) }

            let zip = root.appendingPathComponent("out.zip")
            try PluginExporter.export(pluginDirectory: plugin, to: zip)
            #expect(fm.fileExists(atPath: zip.path))

            let out = root.appendingPathComponent("extracted", isDirectory: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, out.path]
            try process.run()
            process.waitUntilExit()
            #expect(fm.fileExists(atPath: out.appendingPathComponent("MyPlugin/MyPlugin.xml").path))
            #expect(!fm.fileExists(atPath: out.appendingPathComponent("MyPlugin/data").path))
        }
    }
#endif
