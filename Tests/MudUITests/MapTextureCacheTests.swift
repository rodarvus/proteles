#if os(macOS)
    import AppKit
    @testable import MudUI
    import Testing

    /// The texture-resolution ladder (#11): the user's `MapImages/` file always
    /// wins, the bundled defaults sit behind it, and a user file dropped in
    /// mid-session overrides an already-served bundled default on the next
    /// lookup (no restart, no reload command).
    @MainActor
    @Suite("MapTextureCache — user-over-bundled resolution")
    struct MapTextureCacheTests {
        private struct Dirs {
            let user: URL
            let bundled: URL
            let root: URL
        }

        private func makeDirs() throws -> Dirs {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("map-tex-\(UUID().uuidString)", isDirectory: true)
            let user = root.appendingPathComponent("user", isDirectory: true)
            let bundled = root.appendingPathComponent("bundled", isDirectory: true)
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
            return Dirs(user: user, bundled: bundled, root: root)
        }

        /// A 2×2 solid-colour PNG, so loads are verifiable by pixel colour.
        private func writePNG(_ url: URL, red: CGFloat) throws {
            let image = NSImage(size: NSSize(width: 2, height: 2))
            image.lockFocus()
            NSColor(calibratedRed: red, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 2, height: 2).fill()
            image.unlockFocus()
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: url)
        }

        private func redComponent(_ image: NSImage) -> CGFloat {
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            return rep.colorAt(x: 0, y: 0)?
                .usingColorSpace(.deviceRGB)?.redComponent ?? -1
        }

        @Test("user file wins; bundled serves the rest; garbage names refused")
        func resolutionLadder() throws {
            let dirs = try makeDirs()
            defer { try? FileManager.default.removeItem(at: dirs.root) }
            try writePNG(dirs.user.appendingPathComponent("grass1.png"), red: 1.0)
            try writePNG(dirs.bundled.appendingPathComponent("grass1.png"), red: 0.0)
            try writePNG(dirs.bundled.appendingPathComponent("ocean1.png"), red: 0.0)

            let cache = MapTextureCache()
            cache.userDirectory = dirs.user
            cache.bundledDirectory = dirs.bundled

            // Same name in both → the user's (red) copy wins.
            let grass = try #require(cache.image(named: "grass1.png"))
            #expect(redComponent(grass) > 0.9)
            // Bundled-only name → the default serves.
            #expect(cache.image(named: "ocean1.png") != nil)
            // Nowhere → nil; path-like names are refused outright.
            #expect(cache.image(named: "lava.png") == nil)
            #expect(cache.image(named: "../grass1.png") == nil)
            #expect(cache.image(named: "a/b.png") == nil)
        }

        @Test("a user file dropped in mid-session overrides a served bundled default")
        func midSessionDropInOverridesBundled() throws {
            let dirs = try makeDirs()
            defer { try? FileManager.default.removeItem(at: dirs.root) }
            try writePNG(dirs.bundled.appendingPathComponent("hell.png"), red: 0.0)

            let cache = MapTextureCache()
            cache.userDirectory = dirs.user
            cache.bundledDirectory = dirs.bundled

            // First lookup serves (and caches) the bundled default…
            let before = try #require(cache.image(named: "hell.png"))
            #expect(redComponent(before) < 0.1)
            // …then the user drops their own copy in; the next lookup must
            // pick it up despite the bundled cache entry.
            try writePNG(dirs.user.appendingPathComponent("hell.png"), red: 1.0)
            let after = try #require(cache.image(named: "hell.png"))
            #expect(redComponent(after) > 0.9)
        }
    }
#endif
