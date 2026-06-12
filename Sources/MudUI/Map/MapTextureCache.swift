#if os(macOS)
    import AppKit
    import MudCore

    /// Loads + caches the map's per-area background textures: the user's own
    /// files in `~/Documents/Proteles/MapImages/` first, then the bundled
    /// defaults (`DefaultMapTextures/`, generated from scratch by
    /// `scripts/generate-map-textures.swift` — zero external assets, #11).
    ///
    /// User images cache for the session (the reference mapper does the
    /// same). A bundled-default hit still re-checks the user directory on
    /// each lookup — lookups only happen when the published layout changes
    /// (a room move or a toggle), so a file the user drops in mid-session
    /// overrides the default on their next step, no reload needed.
    @MainActor
    public final class MapTextureCache {
        public static let shared = MapTextureCache()

        private var userImages: [String: NSImage] = [:]
        private var bundledImages: [String: NSImage] = [:]
        /// Where the bundled defaults live; injectable for tests (the real
        /// app resolves `Bundle.main`'s `DefaultMapTextures/`).
        var bundledDirectory: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("DefaultMapTextures", isDirectory: true)
        /// User-image directory override for tests (`nil` = the real
        /// `MapImages/` path).
        var userDirectory: URL?

        /// The texture for a layout's `areaTexture` filename, or nil when no
        /// file exists / isn't an image anywhere. Bare filenames only —
        /// anything path-like (a separator or `..`) is refused, since the
        /// name comes from a database column.
        public func image(named name: String) -> NSImage? {
            guard !name.isEmpty, !name.contains("/"), !name.contains("..")
            else { return nil }
            if let cached = userImages[name] { return cached }
            if let image = loadUserImage(name) {
                userImages[name] = image
                return image
            }
            if let cached = bundledImages[name] { return cached }
            guard let bundledDirectory,
                  let image = NSImage(contentsOf: bundledDirectory.appendingPathComponent(name))
            else { return nil }
            bundledImages[name] = image
            return image
        }

        private func loadUserImage(_ name: String) -> NSImage? {
            guard let directory = userDirectory ?? (try? ProtelesPaths.mapImagesDirectory())
            else { return nil }
            return NSImage(contentsOf: directory.appendingPathComponent(name))
        }
    }
#endif
