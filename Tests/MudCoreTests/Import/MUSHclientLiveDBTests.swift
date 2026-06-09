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

    @Test("only the newest mapper/S&D survives; per-character DBs all kept")
    func liveSingletons() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let entries: [ImportManifest.DatabaseEntry] = [
            .init(url: URL(fileURLWithPath: "/a/Aardwolf.db"), kind: .mapper, byteSize: 9, modified: old),
            .init(url: URL(fileURLWithPath: "/b/Aardwolf.db"), kind: .mapper, byteSize: 1, modified: new),
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
        let mappers = kept.filter { $0.kind == .mapper }
        #expect(mappers.count == 1)
        #expect(mappers.first?.url.path == "/b/Aardwolf.db") // the newer one
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
