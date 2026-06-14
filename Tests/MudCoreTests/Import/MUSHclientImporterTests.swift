import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclientImporter — end-to-end coordinator")
struct MUSHclientImporterTests {
    private static let pid = "aaaaaaaaaaaaaaaaaaaaaaaa"

    private func makeWorld() -> MUSHclientWorldFile {
        MUSHclientWorldFile(
            name: "Aardwolf",
            host: "aardmud.org",
            port: 23,
            username: "hero",
            password: "pw",
            macros: [.init(name: "Alt+A", send: "kill rat", type: "send_now")],
            keypad: [.init(key: "8", send: "north")]
        )
    }

    private func makeManifest(pluginXML: URL, dbSrc: URL) -> ImportManifest {
        let plugin = ImportManifest.PluginEntry(
            include: "mything.xml",
            filename: "mything.xml",
            pluginID: Self.pid,
            name: "MyThing",
            resolvedPath: pluginXML,
            copyRoot: pluginXML,
            isMultiFile: false,
            classification: .offer
        )
        let summary = ImportManifest.WorldSummary(
            name: "Aardwolf",
            host: "aardmud.org",
            port: 23,
            username: "hero",
            hasPassword: true,
            macroCount: 1
        )
        return ImportManifest(
            world: summary,
            plugins: [plugin],
            databases: [.init(url: dbSrc, kind: .dinv, character: "Hero", byteSize: 2)],
            stateFiles: [.init(pluginID: Self.pid, variables: ["k": "v"])]
        )
    }

    private func makeEnv(root: URL, scriptsDir: URL) -> MUSHclientImporter.Environment {
        MUSHclientImporter.Environment(
            profiles: ProfileStore(url: root.appendingPathComponent("worlds.json")),
            credentials: InMemoryCredentialStore(),
            library: PluginLibraryStore(url: root.appendingPathComponent("lib.json")),
            pluginsDirectory: root.appendingPathComponent("Plugins"),
            databasesDirectory: root.appendingPathComponent("Databases"),
            makeScriptStore: { ScriptStore(directory: scriptsDir, character: $0) },
            makeVariableStore: { VariableStore(url: root.appendingPathComponent("vars-\($0).json")) },
            now: Date()
        )
    }

    @Test("imports profile + macros + keypad + offer plugin + database")
    func endToEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let xml = root.appendingPathComponent("mything.xml")
        try #"<muclient><plugin name="MyThing" id="\#(Self.pid)"></plugin></muclient>"#
            .write(to: xml, atomically: true, encoding: .utf8)
        let dbSrc = root.appendingPathComponent("dinv.db")
        try Data("db".utf8).write(to: dbSrc)
        let scriptsDir = root.appendingPathComponent("Scripts")

        let env = makeEnv(root: root, scriptsDir: scriptsDir)
        try await env.profiles.load()
        try await env.library.load()
        let selection = MUSHclientImporter.Selection(
            importScriptsAndKeypad: true,
            pluginIncludes: ["mything.xml"],
            databasePaths: [dbSrc.path],
            target: .newProfile(name: "Aardwolf (imported)"),
            character: "Hero"
        )

        let result = try await MUSHclientImporter.run(
            world: makeWorld(),
            manifest: makeManifest(pluginXML: xml, dbSrc: dbSrc),
            selection: selection,
            into: env
        )
        #expect(result.problems.isEmpty)

        let profile = try #require(await env.profiles.profiles.first { $0.id == result.profileID })
        #expect(profile.host == "aardmud.org" && profile.autologin?.username == "hero")
        let store = ScriptStore(directory: scriptsDir, character: "Hero")
        try await store.load()
        #expect(await store.macros.contains { $0.action == .command("kill rat") })
        #expect(await store.keypad.command(for: .num8) == "north")
        #expect(await env.library.enabled(forProfile: result.profileID).contains { $0.pluginID == Self.pid })
        #expect(FileManager.default.fileExists(
            atPath: env.databasesDirectory.appendingPathComponent("Hero/dinv.db").path
        ))
    }

    @Test("world-level variables seed the _user scope on import")
    func worldVariablesSeedUserScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let env = makeEnv(root: root, scriptsDir: root.appendingPathComponent("Scripts"))
        try await env.profiles.load()
        try await env.library.load()
        var world = makeWorld()
        world.variables = ["target": "kobold", "autosac": "on"]
        var manifest = makeManifest(
            pluginXML: root.appendingPathComponent("unused.xml"),
            dbSrc: root.appendingPathComponent("unused.db")
        )
        manifest.plugins = []
        manifest.databases = []
        manifest.stateFiles = []

        let result = try await MUSHclientImporter.run(
            world: world,
            manifest: manifest,
            selection: .init(
                importScriptsAndKeypad: false,
                pluginIncludes: [],
                databasePaths: [],
                target: .newProfile(name: "Aardwolf (imported)"),
                character: "Hero"
            ),
            into: env
        )
        #expect(result.problems.isEmpty)

        let vars = VariableStore(url: root.appendingPathComponent("vars-\(result.profileID).json"))
        try await vars.load()
        #expect(await vars.scopes["_user"] == ["target": "kobold", "autosac": "on"])
    }

    @Test("map background textures copy to MapImages — never clobbering existing files")
    func mapImages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The install's worlds/plugins/images, plus a non-image straggler.
        let source = root.appendingPathComponent("install/worlds/plugins/images")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new-forest".utf8).write(to: source.appendingPathComponent("forest.png"))
        try Data("new-sand".utf8).write(to: source.appendingPathComponent("sand.png"))
        try Data("notes".utf8).write(to: source.appendingPathComponent("readme.txt"))

        // The scanner reports the folder + image count (txt excluded).
        let entry = try #require(MUSHclientInstallScanner.scanMapImages(
            pluginsDirectory: source.deletingLastPathComponent()
        ))
        #expect(entry.count == 2)

        // Destination already holds a customised forest.png — it must survive.
        let destination = root.appendingPathComponent("MapImages")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("customised".utf8).write(to: destination.appendingPathComponent("forest.png"))

        var env = makeEnv(root: root, scriptsDir: root.appendingPathComponent("Scripts"))
        env.mapImagesDirectory = destination
        try await env.profiles.load()
        try await env.library.load()
        var manifest = makeManifest(
            pluginXML: root.appendingPathComponent("unused.xml"),
            dbSrc: root.appendingPathComponent("unused.db")
        )
        manifest.plugins = []
        manifest.databases = []
        manifest.mapImages = entry

        let result = try await MUSHclientImporter.run(
            world: makeWorld(),
            manifest: manifest,
            selection: .init(
                importScriptsAndKeypad: false,
                pluginIncludes: [],
                databasePaths: [],
                target: .newProfile(name: "Aardwolf (imported)"),
                character: "Hero"
            ),
            into: env
        )
        #expect(result.problems.isEmpty)
        let copied = try String(contentsOf: destination.appendingPathComponent("sand.png"), encoding: .utf8)
        #expect(copied == "new-sand")
        let kept = try String(contentsOf: destination.appendingPathComponent("forest.png"), encoding: .utf8)
        #expect(kept == "customised")
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("readme.txt").path
        ))
    }

    @Test("soundpack wavs copy to Sounds — user files kept (#10 tier 1)")
    func sounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("install/sounds")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("their-ding".utf8).write(to: source.appendingPathComponent("quest.wav"))
        try Data("their-tick".utf8).write(to: source.appendingPathComponent("tick.wav"))
        try Data("notes".utf8).write(to: source.appendingPathComponent("readme.txt"))

        let entry = try #require(MUSHclientInstallScanner.scanSounds(
            root: root.appendingPathComponent("install")
        ))
        #expect(entry.count == 2)

        let destination = root.appendingPathComponent("Sounds")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("customised".utf8).write(to: destination.appendingPathComponent("quest.wav"))

        var env = makeEnv(root: root, scriptsDir: root.appendingPathComponent("Scripts"))
        env.soundsDirectory = destination
        try await env.profiles.load()
        try await env.library.load()
        var manifest = makeManifest(
            pluginXML: root.appendingPathComponent("unused.xml"),
            dbSrc: root.appendingPathComponent("unused.db")
        )
        manifest.plugins = []
        manifest.databases = []
        manifest.sounds = entry

        let result = try await MUSHclientImporter.run(
            world: makeWorld(),
            manifest: manifest,
            selection: .init(
                importScriptsAndKeypad: false,
                pluginIncludes: [],
                databasePaths: [],
                target: .newProfile(name: "Aardwolf (imported)"),
                character: "Hero"
            ),
            into: env
        )
        #expect(result.problems.isEmpty)
        let copied = try String(contentsOf: destination.appendingPathComponent("tick.wav"), encoding: .utf8)
        #expect(copied == "their-tick")
        let kept = try String(contentsOf: destination.appendingPathComponent("quest.wav"), encoding: .utf8)
        #expect(kept == "customised")
    }

    /// Build the two-sided S&D fixture: THEIR folder in a fake install (plus
    /// a `-V2` decoy the scanner must skip) and OUR packaged install dir.
    private func makeSnDFolders(under root: URL) throws -> (ours: URL, theirs: URL) {
        let theirs = root.appendingPathComponent("install/worlds/plugins/Search-and-Destroy")
        try FileManager.default.createDirectory(
            at: theirs.appendingPathComponent("lua"), withIntermediateDirectories: true
        )
        try Data("their-xml".utf8).write(to: theirs.appendingPathComponent("Search_and_Destroy.xml"))
        try Data("their-areas".utf8).write(
            to: theirs.appendingPathComponent("lua/areaReferences.lua")
        )
        let ours = root.appendingPathComponent("Plugins/search-and-destroy")
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)
        try Data("our-xml".utf8).write(to: ours.appendingPathComponent("Search_and_Destroy.xml"))
        try Data("our-core".utf8).write(to: ours.appendingPathComponent("core.lua"))
        let decoy = root.appendingPathComponent("install/worlds/plugins/Search-and-Destroy-V2")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try Data("v2".utf8).write(to: decoy.appendingPathComponent("Search_and_Destroy.xml"))
        return (ours, theirs)
    }

    @Test("the install's S&D copies over ours only on explicit opt-in (#53)")
    func searchAndDestroyChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (ours, _) = try makeSnDFolders(under: root)

        // The scanner finds their folder (and skips the -V2 decoy).
        let entry = try #require(MUSHclientInstallScanner.scanSearchAndDestroy(
            root: root.appendingPathComponent("install")
        ))
        #expect(entry.directory.lastPathComponent == "Search-and-Destroy")

        var env = makeEnv(root: root, scriptsDir: root.appendingPathComponent("Scripts"))
        env.searchAndDestroyDirectory = ours
        try await env.profiles.load()
        try await env.library.load()
        var manifest = makeManifest(
            pluginXML: root.appendingPathComponent("unused.xml"),
            dbSrc: root.appendingPathComponent("unused.db")
        )
        manifest.plugins = []
        manifest.databases = []
        manifest.searchAndDestroy = entry
        func selection(_ theirs: Bool) -> MUSHclientImporter.Selection {
            .init(
                importScriptsAndKeypad: false,
                pluginIncludes: [],
                databasePaths: [],
                target: .newProfile(name: "Aardwolf (imported)"),
                character: "Hero",
                importSearchAndDestroyCode: theirs
            )
        }

        // Default (ours): the install dir is untouched.
        _ = try await MUSHclientImporter.run(
            world: makeWorld(), manifest: manifest, selection: selection(false), into: env
        )
        var xml = try String(
            contentsOf: ours.appendingPathComponent("Search_and_Destroy.xml"), encoding: .utf8
        )
        #expect(xml == "our-xml")

        // Opt-in: their XML + lua modules replace ours; core.lua stays (the
        // inert fallback — the XML is the source of truth).
        let result = try await MUSHclientImporter.run(
            world: makeWorld(), manifest: manifest, selection: selection(true), into: env
        )
        #expect(result.problems.isEmpty)
        xml = try String(
            contentsOf: ours.appendingPathComponent("Search_and_Destroy.xml"), encoding: .utf8
        )
        #expect(xml == "their-xml")
        let areas = try String(
            contentsOf: ours.appendingPathComponent("areaReferences.lua"), encoding: .utf8
        )
        #expect(areas == "their-areas")
        let core = try String(contentsOf: ours.appendingPathComponent("core.lua"), encoding: .utf8)
        #expect(core == "our-core")
    }
}
