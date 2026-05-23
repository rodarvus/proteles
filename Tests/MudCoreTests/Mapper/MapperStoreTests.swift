import Foundation
import GRDB
@testable import MudCore
import Testing

@Suite("MapperStore — schema, CRUD, import")
struct MapperStoreTests {
    /// A fresh temp .db path, cleaned up by the caller.
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mapper-test-\(UUID().uuidString).db")
    }

    @Test("Fresh DB round-trips rooms, exits, areas, and notes")
    func roundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MapperStore(url: url)

        try store.upsert(Area(uid: "aylor", name: "Aylor", flags: ""))
        try store.upsert(Room(uid: "100", name: "Town Square", area: "aylor", info: "shop,safe"))
        try store.saveExits(from: "100", exits: [
            "n": Exit(dir: "n", to: "101"),
            "enter portal": Exit(dir: "enter portal", to: "999", level: 10)
        ])
        try store.setNote("vendor here", uid: "100")

        let room = try #require(try store.room(uid: "100"))
        #expect(room.name == "Town Square")
        #expect(room.area == "aylor")
        #expect(room.tags == ["shop", "safe"])
        #expect(room.notes == "vendor here")
        #expect(room.exits["n"]?.to == "101")
        #expect(room.exits["enter portal"]?.to == "999")
        #expect(room.exits["enter portal"]?.level == 10)

        let graph = try store.loadGraph()
        #expect(graph.rooms["100"]?.name == "Town Square")
        #expect(graph.areas["aylor"]?.name == "Aylor")
        #expect(graph.rooms["100"]?.exits.count == 2)
    }

    @Test("Replacing exits removes the old set")
    func replaceExits() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MapperStore(url: url)
        try store.upsert(Room(uid: "1", name: "A"))
        try store.saveExits(from: "1", exits: ["n": Exit(dir: "n", to: "2"), "s": Exit(dir: "s", to: "3")])
        try store.saveExits(from: "1", exits: ["e": Exit(dir: "e", to: "4")])
        let room = try #require(try store.room(uid: "1"))
        #expect(Set(room.exits.keys) == ["e"])
    }

    @Test("Portal pseudo-rooms ('*') load as a from-anywhere room in the graph")
    func portalPseudoRoom() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try MapperStore(url: url)
        try store.saveExits(from: RoomGraph.portalUID, exits: [
            "dinv portal use 42": Exit(dir: "dinv portal use 42", to: "500", level: 100)
        ])
        let graph = try store.loadGraph()
        #expect(graph.rooms[RoomGraph.portalUID]?.exits["dinv portal use 42"]?.to == "500")
    }

    // MARK: - Import / forward-compatibility

    /// Build a pristine MUSHclient-style v11 DB (base tables only, no
    /// Proteles extensions) so we can verify import is non-destructive and
    /// the read-compat columns survive.
    private func makeMUSHclientV11(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = 11")
            try db.execute(sql: """
            CREATE TABLE rooms(uid TEXT NOT NULL, name TEXT, area TEXT, building TEXT, terrain TEXT,
              info TEXT, notes TEXT, x INTEGER, y INTEGER, z INTEGER, norecall INTEGER, noportal INTEGER,
              ignore_exits_mismatch INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(uid));
            CREATE TABLE areas(uid TEXT NOT NULL, name TEXT, texture TEXT, color TEXT,
              flags TEXT NOT NULL DEFAULT '', PRIMARY KEY(uid));
            CREATE TABLE exits(dir TEXT NOT NULL, fromuid TEXT NOT NULL, touid TEXT NOT NULL,
              level STRING NOT NULL DEFAULT '0', PRIMARY KEY(fromuid, dir));
            CREATE TABLE bookmarks(uid TEXT NOT NULL, notes TEXT, PRIMARY KEY(uid));
            CREATE TABLE environments(uid TEXT NOT NULL, name TEXT, color INTEGER, PRIMARY KEY(uid));
            """)
            try db.execute(sql: "INSERT INTO areas(uid,name) VALUES('childsplay','Childsplay')")
            try db.execute(sql: """
            INSERT INTO rooms(uid,name,area,info,noportal,norecall)
            VALUES('676','A Dusty Trail','childsplay','',0,0)
            """)
            try db.execute(sql: "INSERT INTO exits(dir,fromuid,touid,level) VALUES('e','676','677','0')")
            try db.execute(sql: "INSERT INTO bookmarks(uid,notes) VALUES('676','start')")
        }
    }

    @Test("Opening a pristine MUSHclient v11 DB imports it non-destructively")
    func importV11() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try makeMUSHclientV11(at: url)

        // Opening with MapperStore adds our extensions but preserves data.
        let store = try MapperStore(url: url)
        let room = try #require(try store.room(uid: "676"))
        #expect(room.name == "A Dusty Trail")
        #expect(room.area == "childsplay")
        #expect(room.notes == "start")
        #expect(room.exits["e"]?.to == "677")

        // Read-compat: the exact columns Search-and-Destroy SELECTs still work.
        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            let roomRow = try #require(try Row.fetchOne(db, sql: """
            SELECT uid, name, area, info, noportal, norecall, ignore_exits_mismatch
            FROM rooms WHERE uid='676'
            """))
            #expect(roomRow["uid"] as String? == "676")
            let exitRow = try #require(try Row.fetchOne(
                db, sql: "SELECT dir, fromuid, touid, level FROM exits WHERE fromuid='676'"
            ))
            #expect(exitRow["touid"] as String? == "677")
            let areaRow = try #require(try Row.fetchOne(
                db, sql: "SELECT uid, name FROM areas WHERE uid='childsplay'"
            ))
            #expect(areaRow["name"] as String? == "Childsplay")
            // Our extensions were added.
            let version = try String.fetchOne(
                db, sql: "SELECT value FROM proteles_meta WHERE key='schema_version'"
            )
            #expect(version == String(MapperStore.protelesSchemaVersion))
        }
    }

    @Test("An older DB missing flag columns gets them added defensively")
    func importOlderMissingColumns() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // A v4-ish rooms table with no noportal/norecall/ignore_exits_mismatch.
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = 4")
            try db
                .execute(sql: "CREATE TABLE rooms(uid TEXT NOT NULL, name TEXT, area TEXT, PRIMARY KEY(uid))")
            try db.execute(sql: "INSERT INTO rooms(uid,name,area) VALUES('5','Old Room','oldarea')")
        }

        let store = try MapperStore(url: url)
        let room = try #require(try store.room(uid: "5"))
        #expect(room.name == "Old Room")
        #expect(room.noportal == false) // added column defaults to NULL → false
        #expect(room.ignoreExitsMismatch == false)
    }
}
