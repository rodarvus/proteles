import Foundation
@testable import MudCore
import Testing

@Suite("MUSHclientImportScan — real install entry", .enabled(if: FileManager.default.fileExists(
    atPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows/worlds/Aardwolf.mcl"
)))
struct MUSHclientImportScanRealTests {
    @Test("scans the live install: picks the primary world, full manifest")
    func real() throws {
        let root = URL(fileURLWithPath: "/Users/rodarvus/code/proteles/MUSHclient-live-from-windows")
        let scan = try MUSHclientImportScan.scan(installRoot: root)
        #expect(scan.world.name == "Aardwolf")
        #expect(scan.world.pluginIncludes.count == 48) // the full world, not _no_visuals
        #expect(scan.manifest.plugins.count == 48)
        #expect(scan.manifest.databases.contains { $0.kind == .mapper })
        #expect(scan.worldFileNames.count >= 2) // Aardwolf.mcl + Aardwolf_no_visuals.mcl
        #expect(scan.worldFileNames.first == "Aardwolf.mcl") // primary first
    }

    @Test("a directory with no world file throws")
    func empty() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: MUSHclientImportScan.ScanError.self) {
            _ = try MUSHclientImportScan.scan(installRoot: empty)
        }
    }
}
