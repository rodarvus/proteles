import Foundation
@testable import MudCore
import Testing

@Suite("DatabaseImporter — destination routing + copy")
struct DatabaseImporterTests {
    private func entry(
        _ kind: ImportManifest.DatabaseKind,
        _ path: String,
        character: String? = nil
    ) -> ImportManifest.DatabaseEntry {
        .init(url: URL(fileURLWithPath: path), kind: kind, character: character, byteSize: 0)
    }

    @Test("destinations: mapper/S&D global; dinv per its own character; leveldb/plugin per target")
    func destinations() {
        let dbs = URL(fileURLWithPath: "/Proteles/Databases")
        func dest(_ record: ImportManifest.DatabaseEntry, _ char: String = "Hero") -> String? {
            DatabaseImporter.destination(for: record, character: char, in: dbs)?.path
        }
        #expect(dest(entry(.mapper, "/x/Aardwolf.db")) == "/Proteles/Databases/Aardwolf.db")
        #expect(dest(entry(.searchAndDestroy, "/x/SnDdb.db")) == "/Proteles/Databases/SnDdb.db")
        #expect(dest(entry(.dinv, "/x/dinv.db", character: "Liasemus")) ==
            "/Proteles/Databases/Liasemus/dinv.db")
        #expect(dest(entry(.leveldb, "/x/leveldb.db")) == "/Proteles/Databases/Hero/leveldb.db")
        #expect(dest(entry(.pluginOwned, "/x/thing.db")) == "/Proteles/Databases/Hero/thing.db")
        #expect(dest(entry(.unknown, "/x/mystery.db")) == nil)
    }

    @Test("copy: places the file at the destination, creating dirs")
    func copyFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("dinv.db")
        try Data("sqlite-ish".utf8).write(to: src)
        let dbs = tmp.appendingPathComponent("Databases")

        let record = ImportManifest.DatabaseEntry(url: src, kind: .dinv, character: "Hero", byteSize: 0)
        let dest = try #require(try DatabaseImporter.copy(record, character: "Hero", in: dbs))
        #expect(dest.path.hasSuffix("Databases/Hero/dinv.db"))
        #expect(FileManager.default.fileExists(atPath: dest.path))
        // unknown is skipped (returns nil, no copy)
        let unknown = ImportManifest.DatabaseEntry(url: src, kind: .unknown, byteSize: 0)
        #expect(try DatabaseImporter.copy(unknown, character: "Hero", in: dbs) == nil)
    }
}
