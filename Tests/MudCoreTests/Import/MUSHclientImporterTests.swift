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
}
