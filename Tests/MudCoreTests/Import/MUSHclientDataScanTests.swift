import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclient state-file parse + db typing (import)")
struct MUSHclientDataScanTests {
    @Test("state file: variables parsed; plugin id recovered from filename")
    func stateFile() {
        let xml = """
        <?xml version="1.0" encoding="iso-8859-1"?>
        <muclient><variables>
          <variable name="last_target">a knight</variable>
          <variable name="count">7</variable>
        </variables></muclient>
        """
        let vars = MUSHclientStateFile.parseVariables(Data(xml.utf8))
        #expect(vars["last_target"] == "a knight")
        #expect(vars["count"] == "7")

        let pid = MUSHclientStateFile.pluginID(
            fromFilename: "e0eb198d8d5698e3b2f61483-aaaaaaaaaaaaaaaaaaaaaaaa-state.xml",
            worldID: "e0eb198d8d5698e3b2f61483"
        )
        #expect(pid == "aaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(MUSHclientStateFile.pluginID(fromFilename: "notstate.xml", worldID: "x") == nil)
    }

    @Test("db typing: names → kinds; junk/backup/duplicates skipped; dinv carries character")
    func dbTyping() {
        func kind(_ path: String) -> (ImportManifest.DatabaseKind, String?)? {
            MUSHclientInstallScanner.databaseKind(for: URL(fileURLWithPath: path))
        }
        #expect(kind("/x/Aardwolf.db")?.0 == .mapper)
        #expect(kind("/x/SnDdb.db")?.0 == .searchAndDestroy)
        #expect(kind("/x/worlds/plugins/leveldb/leveldb.db")?.0 == .leveldb)
        let dinv = kind("/x/worlds/plugins/state/dinv-731f94b0f2b54345f836bbaf/Hero/dinv.db")
        #expect(dinv?.0 == .dinv)
        #expect(dinv?.1 == "Hero")
        // skipped
        #expect(kind("/x/worlds/plugins/Search-and-Destroy-V2/Aardwolf.db") == nil)
        #expect(kind("/x/worlds/plugins/WinkleGold_Database.db") == nil)
        #expect(kind("/x/dinv/Hero/backup/pre-build-1.db") == nil)
        // plugin-owned (in a state subdir, unrecognised name)
        #expect(kind("/x/worlds/plugins/state/something-id/something.db")?.0 == .pluginOwned)
    }
}

@Suite("MUSHclient full scan — real install", .enabled(if: FileManager.default.fileExists(
    atPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl"
)))
struct MUSHclientFullScanRealTests {
    @Test("scan() yields databases (mapper/S&D/dinv-per-character/leveldb) + parsed state")
    func real() throws {
        let root = URL(fileURLWithPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows")
        let world = try #require(try MUSHclientWorldParser.parse(
            Data(contentsOf: root.appendingPathComponent("worlds/Aardwolf.mcl"))
        ))
        let manifest = MUSHclientInstallScanner.scan(root: root, world: world)

        let kinds = Set(manifest.databases.map(\.kind))
        #expect(kinds.contains(.mapper))
        #expect(kinds.contains(.searchAndDestroy))
        #expect(kinds.contains(.dinv))
        #expect(kinds.contains(.leveldb))
        let dinvChars = Set(manifest.databases.filter { $0.kind == .dinv }.compactMap(\.character))
        print("REAL scan → dbs:\(manifest.databases.count) "
            + "dinvChars:\(dinvChars.sorted()) state:\(manifest.stateFiles.count)")
        #expect(dinvChars.count >= 2) // multiple characters captured
        #expect(manifest.stateFiles.count >= 20) // plenty of plugin state parsed
        #expect(manifest.world.hasPassword) // autologin password detected (value never surfaced)
    }
}
