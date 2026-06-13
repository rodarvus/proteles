import ImageIO
import MudCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The UI-side model of the live MUSHclient miniwindows. Subscribes to
/// ``SessionController/miniWindowUpdates`` and holds the latest scene per
/// window; ``MiniWindowOverlay`` renders them with a SwiftUI `Canvas`.
///
/// This is the miniwindow analogue of `SnDPanelModel` / `MapPanelModel`: an
/// `@Observable` model fed by an `AsyncStream`, so a re-published scene
/// re-renders with no manual invalidation. See
/// `docs/plans/MINIWINDOW_FEASIBILITY.md`.
@MainActor
@Observable
public final class MiniWindowStore {
    /// Latest scene per window name.
    public private(set) var scenes: [String: MiniWindowScene] = [:]
    /// Decoded images keyed `"pluginID\u{1}imageID"` (Phase 3). Held outside the
    /// scene values so the (large) bytes never cross the effect boundary.
    private var images: [String: CGImage] = [:]

    public init() {}

    /// Scenes in a stable draw order (z-order, then name) — lower z first, so
    /// higher-z windows render on top.
    public var orderedScenes: [MiniWindowScene] {
        scenes.values.sorted {
            $0.zOrder != $1.zOrder ? $0.zOrder < $1.zOrder : $0.name < $1.name
        }
    }

    /// Subscribe to the session's miniwindow stream for the view's lifetime.
    public func run(session: SessionController) async {
        for await update in session.miniWindowUpdates {
            apply(update)
        }
    }

    func apply(_ update: MiniWindowUpdate) {
        switch update {
        case .update(let scene): scenes[scene.name] = scene
        case .delete(let name): scenes[name] = nil
        case .image(let pluginID, let imageID, let data):
            if let image = Self.decode(data) { setImage(image, pluginID: pluginID, imageID: imageID) }
        }
    }

    /// Decode PNG/BMP/JPEG bytes to a `CGImage` via ImageIO.
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Look up a decoded image for a scene's `imageID` (Phase 3).
    func image(pluginID: String, imageID: String) -> CGImage? {
        images["\(pluginID)\u{1}\(imageID)"]
    }

    /// Register a decoded image (Phase 3 image loading).
    func setImage(_ image: CGImage, pluginID: String, imageID: String) {
        images["\(pluginID)\u{1}\(imageID)"] = image
    }
}
