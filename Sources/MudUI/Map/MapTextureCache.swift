#if os(macOS)
    import AppKit
    import MudCore

    /// Loads + caches the map's per-area background textures from
    /// `~/Documents/Proteles/MapImages/` (the user's own copies — Proteles
    /// ships no image files, #11).
    ///
    /// Loaded images cache for the session (the reference mapper does the
    /// same). Misses are re-checked on each lookup — lookups only happen when
    /// the published layout changes (a room move or a toggle), so a file the
    /// user drops in mid-session appears on their next step with no reload
    /// command needed.
    @MainActor
    public final class MapTextureCache {
        public static let shared = MapTextureCache()

        private var images: [String: NSImage] = [:]

        /// The texture for a layout's `areaTexture` filename, or nil when the
        /// file doesn't exist / isn't an image. Bare filenames only — anything
        /// path-like (a separator or `..`) is refused, since the name comes
        /// from a database column.
        public func image(named name: String) -> NSImage? {
            if let cached = images[name] { return cached }
            guard !name.isEmpty, !name.contains("/"), !name.contains(".."),
                  let directory = try? ProtelesPaths.mapImagesDirectory()
            else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let image = NSImage(contentsOf: url) else { return nil }
            images[name] = image
            return image
        }
    }
#endif
