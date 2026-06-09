import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclientMUSHclientPluginImporter — install offer plugins + seed state")
struct MUSHclientPluginImporterTests {
    @Test("installs an offer plugin into the library (enabled) and seeds its state")
    func installsAndSeeds() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let srcDir = tmp.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let xml = srcDir.appendingPathComponent("mything.xml")
        let pid = "aaaaaaaaaaaaaaaaaaaaaaaa"
        try #"<muclient><plugin name="MyThing" id="\#(pid)"></plugin></muclient>"#
            .write(to: xml, atomically: true, encoding: .utf8)

        let library = PluginLibraryStore(url: tmp.appendingPathComponent("lib.json"))
        try await library.load()
        let variables = VariableStore(url: tmp.appendingPathComponent("vars.json"))
        try await variables.load()
        let profile = UUID()
        let env = MUSHclientPluginImporter.Environment(
            profile: profile,
            pluginsDirectory: tmp.appendingPathComponent("Plugins"),
            library: library,
            variables: variables,
            now: Date()
        )

        let entry = ImportManifest.PluginEntry(
            include: "mything.xml",
            filename: "mything.xml",
            pluginID: pid,
            name: "MyThing",
            resolvedPath: xml,
            copyRoot: xml,
            isMultiFile: false,
            classification: .offer
        )
        let state = [ImportManifest.StateFile(pluginID: pid, variables: ["foo": "bar"])]

        let problems = try await MUSHclientPluginImporter.apply(
            plugins: [entry],
            stateFiles: state,
            into: env
        )
        #expect(problems.isEmpty)
        #expect(await library.enabled(forProfile: profile).contains { $0.pluginID == pid })
        #expect(await variables.scopes[pid]?["foo"] == "bar")
    }

    @Test("package/bundled entries are not installed here")
    func skipsNonOffer() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let library = PluginLibraryStore(url: tmp.appendingPathComponent("lib.json"))
        try await library.load()
        let variables = VariableStore(url: tmp.appendingPathComponent("vars.json"))
        try await variables.load()
        let profile = UUID()
        let env = MUSHclientPluginImporter.Environment(
            profile: profile,
            pluginsDirectory: tmp.appendingPathComponent("P"),
            library: library,
            variables: variables,
            now: Date()
        )
        let pkg = ImportManifest.PluginEntry(
            include: "aard_x.xml",
            filename: "aard_x.xml",
            pluginID: "b",
            name: "X",
            resolvedPath: nil,
            copyRoot: nil,
            isMultiFile: false,
            classification: .package
        )
        let problems = try await MUSHclientPluginImporter.apply(plugins: [pkg], stateFiles: [], into: env)
        #expect(problems.isEmpty)
        #expect(await library.enabled(forProfile: profile).isEmpty)
    }
}
