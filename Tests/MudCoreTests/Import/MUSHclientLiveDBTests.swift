import Foundation
@testable import MudCore
import Testing

@Suite("Import — live-DB dedupe + already-installed reclassification")
struct MUSHclientLiveDBTests {
    @Test("db_backups paths are skipped")
    func backupSkipped() {
        func kind(_ path: String) -> ImportManifest.DatabaseKind? {
            MUSHclientInstallScanner.databaseKind(for: URL(fileURLWithPath: path))?.0
        }
        #expect(kind("/x/db_backups/Aardwolf.db") == nil)
        #expect(kind("/x/worlds/Aardwolf.db") == .mapper) // a real one still types
    }

    @Test("the largest copy survives a newer-but-empty one; per-character DBs all kept")
    func liveSingletons() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let entries: [ImportManifest.DatabaseEntry] = [
            // A newer 0-byte placeholder must NOT beat the real (larger, older) db.
            .init(url: URL(fileURLWithPath: "/a/leveldb.db"), kind: .leveldb, byteSize: 999, modified: old),
            .init(url: URL(fileURLWithPath: "/b/leveldb.db"), kind: .leveldb, byteSize: 0, modified: new),
            .init(
                url: URL(fileURLWithPath: "/c/dinv.db"),
                kind: .dinv,
                character: "A",
                byteSize: 1,
                modified: old
            ),
            .init(
                url: URL(fileURLWithPath: "/d/dinv.db"),
                kind: .dinv,
                character: "B",
                byteSize: 1,
                modified: old
            )
        ]
        let kept = MUSHclientInstallScanner.liveSingletons(entries)
        let leveldbs = kept.filter { $0.kind == .leveldb }
        #expect(leveldbs.count == 1)
        // the larger (real) one, not the newer-but-empty placeholder
        #expect(leveldbs.first?.url.path == "/a/leveldb.db")
        #expect(kept.count(where: { $0.kind == .dinv }) == 2) // both characters kept
    }

    @Test("markingAlreadyInstalled reclassifies offer plugins present in the library")
    func alreadyInstalled() {
        let manifest = ImportManifest(
            world: .init(name: "W", host: "h", port: 23, username: "", hasPassword: false, macroCount: 0),
            plugins: [
                .init(
                    include: "a.xml",
                    filename: "a.xml",
                    pluginID: "id-a",
                    name: "A",
                    resolvedPath: nil,
                    copyRoot: nil,
                    isMultiFile: false,
                    classification: .offer
                ),
                .init(
                    include: "b.xml",
                    filename: "b.xml",
                    pluginID: "id-b",
                    name: "B",
                    resolvedPath: nil,
                    copyRoot: nil,
                    isMultiFile: false,
                    classification: .offer
                )
            ]
        )
        let marked = manifest.markingAlreadyInstalled(pluginIDs: ["id-a"])
        #expect(marked.plugins.first { $0.pluginID == "id-a" }?.classification == .alreadyInstalled)
        #expect(marked.plugins.first { $0.pluginID == "id-b" }?.classification == .offer)
    }
}

@Suite("Import — plugin data files travel with the plugin")
struct MUSHclientPluginDataFileTests {
    @Test("scanPlugins attaches a plugin's state-dir .db as dataFiles, not a DB entry")
    func attachesDataFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugins = tmp.appendingPathComponent("worlds/plugins")
        let pid = "abc123abc123abc123abc123"
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The plugin .xml directly in plugins/, its db under state/<name>-<id>/.
        try #"<muclient><plugin name="Cool" id="\#(pid)"></plugin></muclient>"#
            .write(to: plugins.appendingPathComponent("cool.xml"), atomically: true, encoding: .utf8)
        let stateDir = plugins.appendingPathComponent("state/cool-\(pid)")
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: stateDir.appendingPathComponent("cool.db"))

        let world = MUSHclientWorldFile(name: "W", host: "h", port: 23, pluginIncludes: ["cool.xml"])
        let (entries, _) = MUSHclientInstallScanner.scanPlugins(world: world, pluginsDirectory: plugins)
        let cool = try #require(entries.first { $0.filename == "cool.xml" })
        #expect(cool.classification == .offer)
        #expect(cool.dataFiles.map(\.lastPathComponent) == ["cool.db"])

        // …and scanDatabases does NOT list it as a standalone database.
        let dbs = MUSHclientInstallScanner.scanDatabases(root: tmp)
        #expect(!dbs.contains { $0.url.lastPathComponent == "cool.db" })
    }
}

@Suite("Import — code-referenced sidecars + leveldb dedup")
struct MUSHclientSidecarTests {
    @Test("a GetInfo(56)-referenced root file becomes a plugin-dir sidecar")
    func codeReferencedSidecar() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugins = root.appendingPathComponent("worlds/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("gag list".utf8).write(to: root.appendingPathComponent("gag.txt"))
        let xml = #"<muclient><plugin name="Gag" id="aaaaaaaaaaaaaaaaaaaaaaaa">"#
            + #"<![CDATA[ for l in io.lines(GetInfo(56) .. "gag.txt") do end ]]></plugin></muclient>"#
        try xml.write(to: plugins.appendingPathComponent("gag.xml"), atomically: true, encoding: .utf8)

        let world = MUSHclientWorldFile(name: "W", host: "h", port: 23, pluginIncludes: ["gag.xml"])
        let (entries, _) = MUSHclientInstallScanner.scanPlugins(world: world, pluginsDirectory: plugins)
        let gag = try #require(entries.first { $0.filename == "gag.xml" })
        #expect(gag.pluginDirSidecars.map(\.lastPathComponent) == ["gag.txt"])
    }
}

@Suite("Import — real install: message_gagger sidecar + single leveldb", .enabled(if:
    FileManager.default.fileExists(
        atPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl"
    )))
struct MUSHclientRealSidecarTests {
    @Test("message_gagger's messages_to_gag.txt is a plugin-dir sidecar; leveldb deduped to one")
    func real() throws {
        let root = URL(fileURLWithPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows")
        let world = try #require(try MUSHclientWorldParser.parse(
            Data(contentsOf: root.appendingPathComponent("worlds/Aardwolf.mcl"))
        ))
        let manifest = MUSHclientInstallScanner.scan(root: root, world: world)

        let gagger = manifest.plugins.first { ($0.name ?? "").localizedCaseInsensitiveContains("gagger") }
        #expect(gagger?.pluginDirSidecars.contains { $0.lastPathComponent == "messages_to_gag.txt" } == true)
        #expect(manifest.databases.count(where: { $0.kind == .leveldb }) == 1)
    }
}

@Suite("Import — code-referenced sidecars don't shadow provided modules")
struct MUSHclientSidecarShadowTests {
    @Test("a GetInfo(60) dofile of a Proteles-provided module (aardwolf_colors) is NOT copied")
    func skipsProvided() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugins = root.appendingPathComponent("worlds/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Both files sit in worlds/plugins (a search root), like the live install.
        try Data("-- gpl".utf8).write(to: plugins.appendingPathComponent("aardwolf_colors.lua"))
        try Data("gag".utf8).write(to: plugins.appendingPathComponent("messages_to_gag.txt"))
        let body = #"dofile(GetInfo(60).."aardwolf_colors.lua")"#
            + #"; io.lines(GetInfo(56).."messages_to_gag.txt")"#
        let xml = #"<muclient><plugin name="P" id="aaaaaaaaaaaaaaaaaaaaaaaa">"#
            + "<![CDATA[ \(body) ]]></plugin></muclient>"
        try xml.write(to: plugins.appendingPathComponent("p.xml"), atomically: true, encoding: .utf8)

        let world = MUSHclientWorldFile(name: "W", host: "h", port: 23, pluginIncludes: ["p.xml"])
        let (entries, _) = MUSHclientInstallScanner.scanPlugins(world: world, pluginsDirectory: plugins)
        let entry = try #require(entries.first { $0.filename == "p.xml" })
        let sidecars = (entry.pluginDirSidecars + entry.dataFiles).map(\.lastPathComponent)
        #expect(!sidecars.contains("aardwolf_colors.lua")) // provided → not shadowed
        #expect(sidecars.contains("messages_to_gag.txt")) // genuine data → still brought
    }
}

@Suite("Import — plugins carry the compatibility report (#47/#1)")
struct MUSHclientPluginReportTests {
    @Test("scanPlugins runs analyze: a plugin needing a missing file is flagged")
    func attachesReport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugins = root.appendingPathComponent("worlds/plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A plugin that requires a module it doesn't ship (and isn't built-in) →
        // analyze warns. The script lives in its own <script> element.
        let xml = """
        <muclient>
        <plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="Needy"/>
        <script><![CDATA[ require "totally_missing_lib" ]]></script>
        </muclient>
        """
        try xml.write(to: plugins.appendingPathComponent("needy.xml"), atomically: true, encoding: .utf8)

        let world = MUSHclientWorldFile(name: "W", host: "h", port: 23, pluginIncludes: ["needy.xml"])
        let (entries, _) = MUSHclientInstallScanner.scanPlugins(world: world, pluginsDirectory: plugins)
        let report = try #require(entries.first { $0.filename == "needy.xml" }?.report)
        #expect(report.verdict == .needsAttention)
        #expect(report.findings.contains { $0.severity == .warning })
    }
}
