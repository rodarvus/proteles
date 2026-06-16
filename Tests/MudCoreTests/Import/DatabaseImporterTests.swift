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

    @Test("copy: overwrites an existing destination; a failed copy preserves it")
    func safeReplace() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dbs = tmp.appendingPathComponent("Databases")
        let src = tmp.appendingPathComponent("leveldb.db")
        try Data("new map".utf8).write(to: src)
        // A non-mapper kind exercises the generic staging-swap copy in isolation
        // (the mapper kind additionally demuxes — covered by MapperSplitTests).
        let record = ImportManifest.DatabaseEntry(url: src, kind: .leveldb, byteSize: 0)

        // Seed an existing destination, then overwrite it.
        let existing = dbs.appendingPathComponent("Hero/leveldb.db")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("old map".utf8).write(to: existing)
        _ = try DatabaseImporter.copy(record, character: "Hero", in: dbs)
        #expect(try Data(contentsOf: existing) == Data("new map".utf8))

        // A failing copy (missing source) must throw AND leave the existing
        // destination intact — the audit found delete-before-copy destroyed
        // the user's DB when the copy failed.
        let missing = ImportManifest.DatabaseEntry(
            url: tmp.appendingPathComponent("nope.db"), kind: .leveldb, byteSize: 0
        )
        #expect(throws: DatabaseImporter.ImportError.self) {
            try DatabaseImporter.copy(missing, character: "Hero", in: dbs)
        }
        #expect(try Data(contentsOf: existing) == Data("new map".utf8), "failed copy clobbered the DB")
    }
}
