import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclient install scanner — plugin resolution + classification")
struct MUSHclientInstallScannerTests {
    private func writePlugin(_ dir: URL, _ rel: String, id: String, name: String) throws {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try #"<muclient><plugin name="\#(name)" id="\#(id)"></plugin></muclient>"#
            .write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("classifies package / bundled / offer, detects multi-file, records missing")
    func classifies() throws {
        let plugins = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString)/worlds/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        defer {
            try? FileManager.default
                .removeItem(at: plugins.deletingLastPathComponent().deletingLastPathComponent())
        }

        // package (by filename), bundled (dinv id, subdir → multi-file), offer (unknown).
        try writePlugin(plugins, "aard_chat_echo.xml", id: "55616ea13339bc68e963e1f8", name: "Chat")
        try writePlugin(plugins, "dinv/dinv.xml", id: "731f94b0f2b54345f836bbaf", name: "dinv")
        try writePlugin(plugins, "cool/mything.xml", id: "aaaaaaaaaaaaaaaaaaaaaaaa", name: "Mine")

        var world = MUSHclientWorldFile()
        world.pluginIncludes = [
            "aard_chat_echo.xml", #"dinv\dinv.xml"#, #"cool\mything.xml"#, #"ghost\ghost.xml"#
        ]
        let (entries, problems) = MUSHclientInstallScanner.scanPlugins(
            world: world,
            pluginsDirectory: plugins
        )

        #expect(entries.count == 4)
        func entry(_ inc: String) -> ImportManifest.PluginEntry {
            entries.first { $0.include == inc }!
        }
        #expect(entry("aard_chat_echo.xml").classification == .package)
        #expect(entry(#"dinv\dinv.xml"#).classification == .bundled)
        #expect(entry(#"dinv\dinv.xml"#).isMultiFile == true)
        #expect(entry(#"cool\mything.xml"#).classification == .offer)
        #expect(entry(#"cool\mything.xml"#).pluginID == "aaaaaaaaaaaaaaaaaaaaaaaa")
        // The missing include is recorded as a problem, not a crash.
        #expect(entry(#"ghost\ghost.xml"#).resolvedPath == nil)
        #expect(problems.contains { $0.item == #"ghost\ghost.xml"# })
    }
}

@Suite("MUSHclient install scanner — real install", .enabled(if: FileManager.default.fileExists(
    atPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl"
)))
struct MUSHclientInstallScannerRealTests {
    @Test("real install: 48 enabled plugins classified, package skipped, no unresolved")
    func real() throws {
        let root = URL(fileURLWithPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows")
        let world = try #require(try MUSHclientWorldParser.parse(
            Data(contentsOf: root.appendingPathComponent("worlds/Aardwolf.mcl"))
        ))
        let (entries, problems) = MUSHclientInstallScanner.scanPlugins(
            world: world, pluginsDirectory: root.appendingPathComponent("worlds/plugins")
        )
        #expect(entries.count == 48)
        let pkg = entries.count(where: { $0.classification == .package })
        let bundled = entries.count(where: { $0.classification == .bundled })
        let offer = entries.count(where: { $0.classification == .offer })
        print("REAL classify → package:\(pkg) bundled:\(bundled) offer:\(offer) problems:\(problems.count)")
        #expect(pkg > 0 && offer > 0) // both buckets populated
        #expect(bundled >= 2) // dinv + S&D at least
        #expect(problems.isEmpty) // every enabled include resolves on disk
    }
}
