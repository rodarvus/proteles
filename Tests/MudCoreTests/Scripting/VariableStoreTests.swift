import Foundation
@testable import MudCore
import Testing

@Suite("VariableStore — persistence", .serialized)
struct VariableStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "proteles-vars-test-\(UUID().uuidString).json"
        )
    }

    @Test("A missing file loads as empty and writes nothing")
    func missingFileIsEmpty() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = VariableStore(url: url)
        try await store.load()
        #expect(await store.scopes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Scopes round-trip through disk")
    func roundTrips() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let scopes = [
            "_user": ["hp": "100", "target": "goblin"],
            "com.x.plugin": ["count": "3"]
        ]
        do {
            let store = VariableStore(url: url)
            try await store.load()
            try await store.replace(with: scopes)
        }

        let reopened = VariableStore(url: url)
        try await reopened.load()
        #expect(await reopened.scopes == scopes)
    }

    @Test("update merges a single scope and persists")
    func updateMergesScope() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = VariableStore(url: url)
        try await store.load()
        try await store.replace(with: ["a": ["x": "1"]])
        try await store.update(scope: "b", variables: ["y": "2"])

        let reopened = VariableStore(url: url)
        try await reopened.load()
        #expect(await reopened.scopes == ["a": ["x": "1"], "b": ["y": "2"]])
    }
}
