import CoreGraphics
import Foundation

// Value types for the MUSHclient *miniwindow* compatibility surface
// (`WindowCreate`/`WindowRectOp`/`WindowText`/…) — the floating 2-D drawing
// panels third-party plugins paint over the output. See
// `docs/plans/MINIWINDOW_FEASIBILITY.md`.
//
// The model is a **retained command-list scene**: each `Window*` draw call
// appends an inert ``MiniWindowCommand`` value to the owning window's scene;
// the runtime emits the whole scene as one ``ScriptEffect/updateMiniWindow(_:)``
// at the end of a draw pass, the session forwards it to the UI, and a SwiftUI
// `Canvas` replays the commands. Keeping the scene a `Sendable`/`Equatable`
// value (rather than letting Lua draw into a live `CGContext`) is what lets the
// draw calls cross the actor boundary under Swift 6 strict concurrency — the
// same discipline ``ScriptEffect`` already follows.

/// A 2-D point in a miniwindow's pixel space (top-left origin). Plain `Double`s
/// rather than `CGPoint` keep `Equatable` synthesis trivial and the type usable
/// from the pure MudCore layer.
public struct MWPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A named font registered into a miniwindow by `WindowFont`. Resolved to an
/// `NSFont`/CoreText font by the renderer; `WindowTextWidth`/`WindowText` look
/// it up by `id`.
public struct MiniWindowFont: Sendable, Equatable {
    public let id: String
    public let name: String
    public let size: Double
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let strikeout: Bool

    public init(
        id: String,
        name: String,
        size: Double,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikeout: Bool = false
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeout = strikeout
    }
}

/// Metadata for an image loaded into a miniwindow by `WindowLoadImage*`.
/// The actual bytes stay in the renderer's image store; the runtime keeps only
/// enough information for synchronous `WindowImageInfo` and list queries.
public struct MiniWindowImageInfo: Sendable, Equatable {
    public let id: String
    public let width: Int
    public let height: Int

    public init(id: String, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}

/// An interactive region (`WindowAddHotspot`). Each callback is a **Lua function
/// name** (a global in the owning plugin's environment) the host invokes when
/// the mouse interacts with the region — mirroring MUSHclient, where hotspot
/// callbacks are passed as strings. Empty string = no callback.
public struct MiniWindowHotspot: Sendable, Equatable {
    public let id: String
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int
    public var mouseOver: String
    public var cancelMouseOver: String
    public var mouseDown: String
    public var cancelMouseDown: String
    public var mouseUp: String
    public var tooltip: String
    public var cursor: Int
    public var flags: Int
    /// `WindowDragHandler` move/release callbacks + `WindowScrollwheelHandler`
    /// callback — installed onto an existing hotspot after it's added.
    public var dragMove: String
    public var dragRelease: String
    public var scrollwheel: String

    public init(
        id: String,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        mouseOver: String = "",
        cancelMouseOver: String = "",
        mouseDown: String = "",
        cancelMouseDown: String = "",
        mouseUp: String = "",
        tooltip: String = "",
        cursor: Int = 0,
        flags: Int = 0,
        dragMove: String = "",
        dragRelease: String = "",
        scrollwheel: String = ""
    ) {
        self.id = id
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
        self.mouseOver = mouseOver
        self.cancelMouseOver = cancelMouseOver
        self.mouseDown = mouseDown
        self.cancelMouseDown = cancelMouseDown
        self.mouseUp = mouseUp
        self.tooltip = tooltip
        self.cursor = cursor
        self.flags = flags
        self.dragMove = dragMove
        self.dragRelease = dragRelease
        self.scrollwheel = scrollwheel
    }
}

/// One drawing primitive recorded into a scene. Coordinates are MUSHclient
/// pixel coordinates (a right/bottom `<= 0` is relative to the window edge — see
/// ``MiniWindowScene/fix(_:extent:)``); colours are BGR ints (red low byte, the
/// `MUSHColour` convention), `-1` meaning "no colour".
public enum MiniWindowCommand: Sendable, Equatable {
    /// `WindowRectOp(action, …)` — action 1 frame, 2 fill, 3 invert, 4 3-D rect,
    /// 5 draw-edge, 6/7 flood fill.
    case rect(action: Int, left: Int, top: Int, right: Int, bottom: Int, colour1: Int, colour2: Int)
    /// `WindowCircleOp(action, …)` — 1 ellipse, 2 rectangle, 3 round-rect,
    /// 4 chord, 5 pie.
    case circle(
        action: Int, left: Int, top: Int, right: Int, bottom: Int,
        penColour: Int, penStyle: Int, penWidth: Int,
        brushColour: Int, brushStyle: Int, extra1: Int, extra2: Int
    )
    /// `WindowText(fontID, text, …)`.
    case text(fontID: String, text: String, left: Int, top: Int, right: Int, bottom: Int, colour: Int)
    /// `WindowLine(x1, y1, x2, y2, …)`.
    case line(x1: Int, y1: Int, x2: Int, y2: Int, colour: Int, penStyle: Int, penWidth: Int)
    /// `WindowSetPixel(x, y, colour)`.
    case setPixel(x: Int, y: Int, colour: Int)
    /// `WindowGradient(…, mode)` — 1 horizontal, 2 vertical.
    case gradient(left: Int, top: Int, right: Int, bottom: Int, startColour: Int, endColour: Int, mode: Int)
    /// `WindowPolygon(points, …)`.
    case polygon(
        points: [MWPoint], penColour: Int, penStyle: Int, penWidth: Int,
        brushColour: Int, brushStyle: Int, close: Bool, winding: Bool
    )
    /// `WindowArc(…)`.
    case arc(
        left: Int, top: Int, right: Int, bottom: Int,
        x1: Int, y1: Int, x2: Int, y2: Int, colour: Int, penStyle: Int, penWidth: Int
    )
    /// `WindowBezier(points, …)`.
    case bezier(points: [MWPoint], colour: Int, penStyle: Int, penWidth: Int)
    /// `WindowDrawImage`/`WindowDrawImageAlpha`/`WindowBlendImage` — the image
    /// bytes live in the renderer's image store keyed by `(pluginID, imageID)`;
    /// the command carries only the id (so the scene value stays small). `mode`
    /// 1 copy, 2 stretch, 3 transparent; `opacity` 0…1 (1 for plain draws).
    case image(
        imageID: String, left: Int, top: Int, right: Int, bottom: Int,
        mode: Int, opacity: Double, srcLeft: Int, srcTop: Int, srcRight: Int, srcBottom: Int
    )
}

/// A complete miniwindow: its geometry/placement/flags plus the retained scene
/// (registered fonts, the ordered draw commands of the current frame, and the
/// hotspots). Identified by its plugin-chosen `name` (world-unique in
/// MUSHclient). `pluginID` is the owning plugin, so hotspot callbacks dispatch
/// back into the right Lua environment.
public struct MiniWindowScene: Sendable, Equatable, Identifiable {
    public let name: String
    public var pluginID: String
    public var width: Int
    public var height: Int
    public var left: Int
    public var top: Int
    /// MUSHclient position constant (0…13); honoured unless
    /// ``createAbsoluteLocation`` is set.
    public var position: Int
    /// MUSHclient `WindowCreate` flags bitfield.
    public var flags: Int
    public var backgroundColour: Int
    public var visible: Bool
    public var zOrder: Int
    public var fonts: [String: MiniWindowFont]
    public var images: [String: MiniWindowImageInfo]
    public var commands: [MiniWindowCommand]
    public var hotspots: [MiniWindowHotspot]

    public var id: String {
        name
    }

    public init(
        name: String,
        pluginID: String,
        width: Int = 0,
        height: Int = 0,
        left: Int = 0,
        top: Int = 0,
        position: Int = 6,
        flags: Int = 0,
        backgroundColour: Int = 0,
        visible: Bool = true,
        zOrder: Int = 0,
        fonts: [String: MiniWindowFont] = [:],
        images: [String: MiniWindowImageInfo] = [:],
        commands: [MiniWindowCommand] = [],
        hotspots: [MiniWindowHotspot] = []
    ) {
        self.name = name
        self.pluginID = pluginID
        self.width = width
        self.height = height
        self.left = left
        self.top = top
        self.position = position
        self.flags = flags
        self.backgroundColour = backgroundColour
        self.visible = visible
        self.zOrder = zOrder
        self.fonts = fonts
        self.images = images
        self.commands = commands
        self.hotspots = hotspots
    }

    // MARK: Create flags (MUSHclient)

    public static let flagUnderneath = 0x01
    public static let flagAbsoluteLocation = 0x02
    public static let flagTransparent = 0x04
    public static let flagIgnoreMouse = 0x08
    public static let flagKeepHotspots = 0x10

    public var createsUnderneath: Bool {
        flags & Self.flagUnderneath != 0
    }

    public var createAbsoluteLocation: Bool {
        flags & Self.flagAbsoluteLocation != 0
    }

    public var ignoresMouse: Bool {
        flags & Self.flagIgnoreMouse != 0
    }

    // MARK: Coordinate + placement helpers (pure; mirror MUSHclient)

    /// MUSHclient `FixRight`/`FixBottom`: a coordinate `<= 0` is relative to the
    /// window's `extent` (so `0` → the far edge, `-1` → one pixel inside).
    public static func fix(_ value: Int, extent: Int) -> CGFloat {
        value <= 0 ? CGFloat(extent + value) : CGFloat(value)
    }

    /// Position-constant → (x, y) fraction of the free space (`container − size`)
    /// the origin sits at: top-left (0,0) … bottom-right (1,1), centre (½,½).
    private static let positionFactors: [Int: (x: CGFloat, y: CGFloat)] = [
        4: (0, 0), 5: (0.5, 0), 6: (1, 0), 7: (1, 0.5), 8: (1, 1),
        9: (0.5, 1), 10: (0, 1), 11: (0, 0.5), 12: (0.5, 0.5)
    ]

    /// The window's top-left origin within a `container` of the given size,
    /// honouring the position constant — unless `create_absolute_location`, in
    /// which case `(left, top)` is used verbatim. Stretch/tile positions fall
    /// back to absolute for the spike.
    public func origin(in container: CGSize) -> CGPoint {
        if createAbsoluteLocation { return CGPoint(x: left, y: top) }
        guard let factor = Self.positionFactors[position] else { return CGPoint(x: left, y: top) }
        let maxX = container.width - CGFloat(width)
        let maxY = container.height - CGFloat(height)
        return CGPoint(x: maxX * factor.x, y: maxY * factor.y)
    }
}

/// A miniwindow change the session forwards to the UI: a fresh scene to render,
/// or a window to remove.
public enum MiniWindowUpdate: Sendable, Equatable {
    case update(MiniWindowScene)
    case delete(name: String)
    /// Decoded image bytes for `(pluginID, imageID)` (Phase 3) — the store
    /// decodes them to a `CGImage` and keys them for `WindowDrawImage`.
    case image(pluginID: String, imageID: String, data: Data)
}

/// A mouse interaction on a miniwindow hotspot, routed UI → session → the
/// owning plugin's named Lua callback. Mirrors MUSHclient's hotspot event,
/// which passes `(flags, hotspotId)` to the callback.
public struct MiniWindowEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case mouseOver, cancelMouseOver
        case mouseDown, cancelMouseDown, mouseUp
        case dragMove, dragRelease
        case scrollwheel
    }

    public let windowName: String
    public let pluginID: String
    public let hotspotID: String
    public let kind: Kind
    /// The Lua global function name the owning plugin registered for this event
    /// (resolved UI-side from the hotspot), invoked with `(flags, hotspotID)`.
    public let callback: String
    /// MUSHclient hotspot flag bits (shift/ctrl/alt/buttons), already packed.
    public let flags: Int
    /// Mouse coordinates in the miniwindow's pixel space at event dispatch.
    public let x: Int
    public let y: Int

    public init(
        windowName: String,
        pluginID: String,
        hotspotID: String,
        kind: Kind,
        callback: String,
        flags: Int,
        x: Int = 0,
        y: Int = 0
    ) {
        self.windowName = windowName
        self.pluginID = pluginID
        self.hotspotID = hotspotID
        self.kind = kind
        self.callback = callback
        self.flags = flags
        self.x = x
        self.y = y
    }
}

/// Decode a MUSHclient BGR colour int (red low byte). Returns `nil` for a
/// negative value (`-1` = "no colour", e.g. a null pen/brush).
public enum MiniWindowColour {
    public struct RGB: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double
    }

    public static func components(_ value: Int) -> RGB? {
        guard value >= 0 else { return nil }
        return RGB(
            red: Double(value & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double((value >> 16) & 0xFF) / 255
        )
    }
}
