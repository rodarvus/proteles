import CoreText
import Foundation

/// Host-side of the MUSHclient miniwindow surface (`proteles.window*`, backing
/// the `Window*` shim globals — see `LuaRuntime+MiniWindowShim`).
///
/// Draw/lifecycle calls mutate the runtime's retained ``LuaRuntime/miniWindows``
/// scene state rather than appending an effect each; ``flushMiniWindows()`` emits
/// one ``ScriptEffect/updateMiniWindow(_:)`` per touched window at the end of the
/// run (see `LuaRuntime.run` / `callGlobal`). The `*Info`/`*Width` calls are
/// synchronous queries that return a value inline (Lua reads them to lay out the
/// following draws).
///
/// Frame model: a plugin redraws its whole window in one Lua pass, so the FIRST
/// draw/hotspot op of a run clears the prior frame's commands+hotspots
/// (``miniWindowFramePainted``) and the rest of the pass rebuilds it — one
/// `.updateMiniWindow` == one frame, which bounds memory and matches the
/// clear-then-redraw idiom (`WindowRectOp` full-window fill, then content).
extension LuaRuntime {
    /// Register the `proteles.window*` host functions backing the `Window*` shim
    /// globals. Called from `installProtelesAPI` with the `proteles` table on the
    /// Lua stack top.
    nonisolated func installProtelesAPIMiniWindow() {
        for (name, id) in Self.miniWindowHostFunctions {
            setHostFunction(name, id)
        }
    }

    /// `proteles.window*` name → host-function id (the registration table).
    private nonisolated static let miniWindowHostFunctions: [(String, HostFunction)] = [
        ("windowCreate", .windowCreate), ("windowShow", .windowShow), ("windowDelete", .windowDelete),
        ("windowResize", .windowResize), ("windowPosition", .windowPosition),
        ("windowSetZOrder", .windowSetZOrder), ("windowRectOp", .windowRectOp),
        ("windowText", .windowText), ("windowLine", .windowLine), ("windowSetPixel", .windowSetPixel),
        ("windowGetPixel", .windowGetPixel), ("windowFont", .windowFont),
        ("windowTextWidth", .windowTextWidth), ("windowInfo", .windowInfo),
        ("windowFontInfo", .windowFontInfo), ("windowList", .windowList), ("windowInfoList", .windowInfoList),
        ("windowFontList", .windowFontList), ("windowImageList", .windowImageList),
        ("windowHotspotList", .windowHotspotList), ("windowAddHotspot", .windowAddHotspot),
        ("windowDeleteHotspot", .windowDeleteHotspot), ("windowDeleteAllHotspots", .windowDeleteAllHotspots),
        ("windowMoveHotspot", .windowMoveHotspot), ("windowHotspotInfo", .windowHotspotInfo),
        ("windowDragHandler", .windowDragHandler), ("windowScrollwheelHandler", .windowScrollwheelHandler),
        ("windowMenu", .windowMenu), ("windowLoadImage", .windowLoadImage), (
            "windowDrawImage",
            .windowDrawImage
        ),
        ("windowImageInfo", .windowImageInfo), ("windowImageFromWindow", .windowImageFromWindow),
        ("windowWrite", .windowWrite),
        ("windowCircleOp", .windowCircleOp),
        ("windowGradient", .windowGradient), ("windowPolygon", .windowPolygon), ("windowArc", .windowArc),
        ("windowBezier", .windowBezier)
    ]

    /// Default-path router for `invokeHostFunction`: a `window*` call goes to the
    /// miniwindow surface; anything else is an event-bus/RPC registration.
    nonisolated func miniWindowOrRegister(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        switch function {
        case .windowCreate, .windowShow, .windowDelete, .windowResize, .windowPosition, .windowSetZOrder,
             .windowRectOp, .windowText, .windowLine, .windowSetPixel, .windowGetPixel, .windowFont,
             .windowTextWidth, .windowInfo, .windowFontInfo, .windowList, .windowInfoList,
             .windowFontList, .windowImageList, .windowHotspotList, .windowAddHotspot, .windowDeleteHotspot,
             .windowDeleteAllHotspots, .windowMoveHotspot, .windowHotspotInfo, .windowDragHandler,
             .windowScrollwheelHandler, .windowMenu, .windowLoadImage, .windowDrawImage,
             .windowImageInfo, .windowImageFromWindow, .windowWrite, .windowCircleOp, .windowGradient,
             .windowPolygon, .windowArc, .windowBezier:
            return miniWindowCall(function, arguments)
        default:
            registerOrRaise(function, arguments)
            return []
        }
    }

    /// Drop every miniwindow a plugin owns (on unload/reload) and return the
    /// `.deleteMiniWindow` effects so the UI removes them — otherwise a removed
    /// plugin's windows linger on screen (its scenes persist in the runtime, and
    /// it may not define an `OnPluginClose` that calls `WindowDelete`).
    nonisolated func removeMiniWindows(ownedBy pluginID: String) -> [ScriptEffect] {
        let owned = miniWindows.filter { $0.value.pluginID == pluginID }.keys.sorted()
        for name in owned {
            miniWindows[name] = nil
            miniWindowsDirty.remove(name)
            miniWindowFramePainted.remove(name)
        }
        return owned.map { .deleteMiniWindow(name: $0) }
    }

    /// Reset the per-run frame bookkeeping (called at the start of `run`/
    /// `callGlobal`). Scene state itself persists across runs.
    nonisolated func beginMiniWindowPass() {
        miniWindowsDirty.removeAll(keepingCapacity: true)
        miniWindowFramePainted.removeAll(keepingCapacity: true)
    }

    /// Emit one `.updateMiniWindow` effect per window touched this run.
    nonisolated func flushMiniWindows() {
        guard !miniWindowsDirty.isEmpty else { return }
        // Stable order so z-equal windows don't restack frame-to-frame.
        for name in miniWindowsDirty.sorted() {
            guard let scene = miniWindows[name] else { continue }
            effects.append(.updateMiniWindow(scene))
        }
        miniWindowsDirty.removeAll(keepingCapacity: true)
    }

    /// Route a `proteles.window*` host call. Returns a value for the query
    /// functions; `[]` for draw/lifecycle mutations.
    nonisolated func miniWindowCall(_ function: HostFunction, _ arguments: [LuaValue]) -> [LuaValue] {
        let name = Self.argString(arguments, 0)
        switch function {
        case .windowCreate, .windowShow, .windowDelete, .windowResize, .windowPosition, .windowSetZOrder,
             .windowFont:
            miniWindowLifecycle(function, name, arguments)
            return []
        case .windowRectOp, .windowLine, .windowSetPixel:
            miniWindowDraw(function, name, arguments)
            return []
        case .windowText:
            return [.number(appendText(name, arguments))]
        case .windowTextWidth, .windowInfo, .windowFontInfo, .windowGetPixel:
            return [miniWindowQuery(function, name, arguments)]
        case .windowList, .windowInfoList, .windowFontList, .windowImageList, .windowHotspotList:
            return [miniWindowListValue(function, name)]
        default:
            return miniWindowExtraCall(function, name, arguments)
        }
    }

    private nonisolated func miniWindowLifecycle(
        _ function: HostFunction, _ name: String, _ arguments: [LuaValue]
    ) {
        switch function {
        case .windowCreate: createMiniWindow(name, arguments)
        case .windowShow: showMiniWindow(name, on: Self.argBool(arguments, 1))
        case .windowDelete: deleteMiniWindow(name)
        case .windowResize: resizeMiniWindow(name, arguments)
        case .windowPosition: positionMiniWindow(name, arguments)
        case .windowSetZOrder: setMiniWindowZOrder(name, arguments)
        default: registerMiniWindowFont(name, arguments) // .windowFont
        }
    }

    private nonisolated func miniWindowDraw(
        _ function: HostFunction, _ name: String, _ arguments: [LuaValue]
    ) {
        switch function {
        case .windowRectOp: appendRectOp(name, arguments)
        case .windowLine: appendLine(name, arguments)
        default: appendSetPixel(name, arguments) // .windowSetPixel
        }
    }

    private nonisolated func miniWindowQuery(
        _ function: HostFunction, _ name: String, _ arguments: [LuaValue]
    ) -> LuaValue {
        switch function {
        case .windowGetPixel:
            miniWindowPixelValue(name, arguments)
        case .windowTextWidth:
            .number(measureMiniWindowText(
                name, fontID: Self.argString(arguments, 1), text: Self.argString(arguments, 2)
            ))
        case .windowFontInfo:
            miniWindowFontInfoValue(
                name, fontID: Self.argString(arguments, 1), info: Int(Self.argDouble(arguments, 2))
            )
        default: // .windowInfo
            miniWindowInfoValue(name, Int(Self.argDouble(arguments, 1)))
        }
    }

    // MARK: - Lifecycle

    private nonisolated func createMiniWindow(_ name: String, _ arguments: [LuaValue]) {
        guard !name.isEmpty else { return }
        let keepHotspots = Int(Self.argDouble(arguments, 6)) & MiniWindowScene.flagKeepHotspots != 0
        let previous = miniWindows[name]
        var scene = MiniWindowScene(
            name: name,
            pluginID: pluginContext.pluginID,
            width: max(0, Int(Self.argDouble(arguments, 3))),
            height: max(0, Int(Self.argDouble(arguments, 4))),
            left: Int(Self.argDouble(arguments, 1)),
            top: Int(Self.argDouble(arguments, 2)),
            position: Int(Self.argDouble(arguments, 5)),
            flags: Int(Self.argDouble(arguments, 6)),
            backgroundColour: Int(Self.argDouble(arguments, 7)),
            visible: previous?.visible ?? true,
            fonts: previous?.fonts ?? [:],
            images: previous?.images ?? [:],
            hotspots: keepHotspots ? (previous?.hotspots ?? []) : []
        )
        // Recreate paints a fresh surface filled with the background colour.
        scene.commands = [.rect(
            action: 2,
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
            colour1: scene.backgroundColour,
            colour2: 0
        )]
        miniWindows[name] = scene
        // Treat the window as already framed this run, so subsequent draws in
        // the same pass append rather than re-clearing the fresh surface.
        miniWindowFramePainted.insert(name)
        miniWindowsDirty.insert(name)
    }

    private nonisolated func showMiniWindow(_ name: String, on: Bool) {
        updateMiniWindow(name) { $0.visible = on }
    }

    private nonisolated func deleteMiniWindow(_ name: String) {
        guard miniWindows.removeValue(forKey: name) != nil else { return }
        miniWindowsDirty.remove(name)
        miniWindowFramePainted.remove(name)
        effects.append(.deleteMiniWindow(name: name))
    }

    private nonisolated func resizeMiniWindow(_ name: String, _ arguments: [LuaValue]) {
        updateMiniWindow(name) {
            $0.width = max(0, Int(Self.argDouble(arguments, 1)))
            $0.height = max(0, Int(Self.argDouble(arguments, 2)))
            $0.backgroundColour = Int(Self.argDouble(arguments, 3))
        }
    }

    private nonisolated func positionMiniWindow(_ name: String, _ arguments: [LuaValue]) {
        updateMiniWindow(name) {
            $0.left = Int(Self.argDouble(arguments, 1))
            $0.top = Int(Self.argDouble(arguments, 2))
            $0.position = Int(Self.argDouble(arguments, 3))
            if arguments.count > 4 { $0.flags = Int(Self.argDouble(arguments, 4)) }
        }
    }

    private nonisolated func setMiniWindowZOrder(_ name: String, _ arguments: [LuaValue]) {
        updateMiniWindow(name) {
            $0.zOrder = Int(Self.argDouble(arguments, 1))
        }
    }

    private nonisolated func registerMiniWindowFont(_ name: String, _ arguments: [LuaValue]) {
        let fontID = Self.argString(arguments, 1)
        guard !fontID.isEmpty else { return }
        let font = MiniWindowFont(
            id: fontID,
            name: Self.argString(arguments, 2),
            size: Self.argDouble(arguments, 3),
            bold: Self.argBool(arguments, 4),
            italic: Self.argBool(arguments, 5),
            underline: Self.argBool(arguments, 6),
            strikeout: Self.argBool(arguments, 7)
        )
        updateMiniWindow(name) { $0.fonts[fontID] = font }
    }

    // MARK: - Phase-1 drawing

    private nonisolated func appendRectOp(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .rect(
            action: Int(Self.argDouble(arguments, 1)),
            left: Int(Self.argDouble(arguments, 2)),
            top: Int(Self.argDouble(arguments, 3)),
            right: Int(Self.argDouble(arguments, 4)),
            bottom: Int(Self.argDouble(arguments, 5)),
            colour1: Int(Self.argDouble(arguments, 6)),
            colour2: Int(Self.argDouble(arguments, 7))
        ))
    }

    private nonisolated func appendLine(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .line(
            x1: Int(Self.argDouble(arguments, 1)),
            y1: Int(Self.argDouble(arguments, 2)),
            x2: Int(Self.argDouble(arguments, 3)),
            y2: Int(Self.argDouble(arguments, 4)),
            colour: Int(Self.argDouble(arguments, 5)),
            penStyle: Int(Self.argDouble(arguments, 6)),
            penWidth: max(1, Int(Self.argDouble(arguments, 7)))
        ))
    }

    private nonisolated func appendSetPixel(_ name: String, _ arguments: [LuaValue]) {
        guard miniWindows[name] != nil else { return }
        beginMiniWindowFrame(name)
        let x = Int(Self.argDouble(arguments, 1))
        let y = Int(Self.argDouble(arguments, 2))
        let colour = Int(Self.argDouble(arguments, 3))
        updateMiniWindow(name) {
            $0.commands.append(.setPixel(x: x, y: y, colour: colour))
            $0.pixels[MiniWindowPixel(x: x, y: y)] = colour
        }
    }

    /// `WindowText` — append the draw and return the drawn width in pixels (what
    /// MUSHclient returns; plugins position the next draw from it).
    private nonisolated func appendText(_ name: String, _ arguments: [LuaValue]) -> Double {
        let fontID = Self.argString(arguments, 1)
        let text = Self.argString(arguments, 2)
        appendMiniWindowCommand(name, .text(
            fontID: fontID,
            text: text,
            left: Int(Self.argDouble(arguments, 3)),
            top: Int(Self.argDouble(arguments, 4)),
            right: Int(Self.argDouble(arguments, 5)),
            bottom: Int(Self.argDouble(arguments, 6)),
            colour: Int(Self.argDouble(arguments, 7))
        ))
        return measureMiniWindowText(name, fontID: fontID, text: text)
    }

    // MARK: - Queries

    /// `WindowInfo(name, infoType)` — geometry, visibility, pointer state, and
    /// owner metadata used by Aardwolf-package miniwindow helpers.
    private nonisolated func miniWindowInfoValue(_ name: String, _ info: Int) -> LuaValue {
        guard let scene = miniWindows[name] else { return .nil }
        if let value = miniWindowBaseInfoValue(scene, info) { return value }
        if let value = miniWindowBoundsInfoValue(scene, info) { return value }
        if let value = miniWindowPointerInfoValue(miniWindowPointerStates[name], info) { return value }
        switch info {
        case 22: return .number(Double(scene.zOrder))
        case 23: return .string(scene.pluginID)
        default: return .nil
        }
    }

    /// `WindowGetPixel` — MUSHclient returns `-2` when the named window does not
    /// exist and the surface colour otherwise. Proteles tracks pixels explicitly
    /// written with `WindowSetPixel`; untouched in-bounds pixels report the
    /// current background colour.
    private nonisolated func miniWindowPixelValue(_ name: String, _ arguments: [LuaValue]) -> LuaValue {
        guard let scene = miniWindows[name] else { return .number(-2) }
        let x = Int(Self.argDouble(arguments, 1))
        let y = Int(Self.argDouble(arguments, 2))
        guard x >= 0, y >= 0, x < scene.width, y < scene.height else { return .number(-1) }
        let pixel = MiniWindowPixel(x: x, y: y)
        return .number(Double(scene.pixels[pixel] ?? scene.backgroundColour))
    }

    private nonisolated func miniWindowBaseInfoValue(_ scene: MiniWindowScene, _ info: Int) -> LuaValue? {
        switch info {
        case 1: .number(Double(scene.left))
        case 2: .number(Double(scene.top))
        case 3: .number(Double(scene.width))
        case 4: .number(Double(scene.height))
        case 5: .boolean(scene.visible)
        case 6: .boolean(false)
        case 7: .number(Double(scene.position))
        case 8: .number(Double(scene.flags))
        case 9: .number(Double(scene.backgroundColour))
        default: nil
        }
    }

    private nonisolated func miniWindowBoundsInfoValue(_ scene: MiniWindowScene, _ info: Int) -> LuaValue? {
        switch info {
        case 10: .number(Double(scene.left))
        case 11: .number(Double(scene.top))
        case 12: .number(Double(scene.left + scene.width))
        case 13: .number(Double(scene.top + scene.height))
        default: nil
        }
    }

    private nonisolated func miniWindowPointerInfoValue(
        _ pointer: MiniWindowPointerState?, _ info: Int
    ) -> LuaValue? {
        switch info {
        case 14: .number(Double(pointer?.downX ?? 0))
        case 15: .number(Double(pointer?.downY ?? 0))
        case 17: .number(Double(pointer?.currentX ?? 0))
        case 18: .number(Double(pointer?.currentY ?? 0))
        case 19: .string(pointer?.hotspotID ?? "")
        case 20: .string(pointer?.downHotspotID ?? "")
        default: nil
        }
    }

    private nonisolated func miniWindowListValue(_ function: HostFunction, _ name: String) -> LuaValue {
        switch function {
        case .windowList:
            pushNameArray(miniWindows.keys.sorted())
        case .windowInfoList:
            pushNameArray(miniWindows[name].map { windowInfoKeys(for: $0) } ?? [])
        case .windowFontList:
            pushNameArray(miniWindows[name]?.fonts.keys.sorted() ?? [])
        case .windowImageList:
            pushNameArray(miniWindows[name]?.images.keys.sorted() ?? [])
        case .windowHotspotList:
            pushNameArray(miniWindows[name]?.hotspots.map(\.id).sorted() ?? [])
        default:
            pushNameArray([])
        }
    }

    private nonisolated func windowInfoKeys(for scene: MiniWindowScene) -> [String] {
        var keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "22", "23"]
        if miniWindowPointerStates[scene.name] != nil {
            keys.append(contentsOf: ["14", "15", "17", "18", "19", "20"])
        }
        return keys
    }

    /// `WindowFontInfo(name, fontID, infoType)` — MUSHclient-compatible font
    /// metrics for layout helpers. Measured via CoreText on the resolved font.
    private nonisolated func miniWindowFontInfoValue(_ name: String, fontID: String, info: Int) -> LuaValue {
        guard let font = miniWindows[name]?.fonts[fontID] else { return .nil }
        let ctFont = Self.coreTextFont(font)
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        if let value = miniWindowFontMetricInfoValue(
            info,
            font: ctFont,
            ascent: ascent,
            descent: descent,
            leading: leading
        ) {
            return value
        }
        if let value = miniWindowFontStyleInfoValue(info, font: font) { return value }
        if info == 21 { return .string(font.name) }
        return .nil
    }

    private nonisolated func miniWindowFontMetricInfoValue(
        _ info: Int,
        font: CTFont,
        ascent: CGFloat,
        descent: CGFloat,
        leading: CGFloat
    ) -> LuaValue? {
        switch info {
        case 1: .number(Double(ceil(ascent + descent + leading))) // height
        case 2: .number(Double(ceil(ascent)))
        case 3: .number(Double(ceil(descent)))
        case 4: .number(0) // internal leading; CoreText has no direct equivalent
        case 5: .number(Double(ceil(leading))) // external leading
        case 6: .number(Self.measureText("n", font: font))
        case 7: .number(Self.measureText("W", font: font))
        default: nil
        }
    }

    private nonisolated func miniWindowFontStyleInfoValue(_ info: Int, font: MiniWindowFont) -> LuaValue? {
        switch info {
        case 8: .number(font.bold ? 700 : 400)
        case 16: .number(font.italic ? 1 : 0)
        case 17: .number(font.underline ? 1 : 0)
        case 18: .number(font.strikeout ? 1 : 0)
        default: nil
        }
    }

    /// Width of `text` in `fontID`, in pixels — CoreText typographic bounds on
    /// the resolved font (the same family/size the Canvas renders with, so the
    /// drift the plan flags is sub-pixel for common fonts).
    nonisolated func measureMiniWindowText(_ name: String, fontID: String, text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = miniWindows[name]?.fonts[fontID]
            ?? MiniWindowFont(id: fontID, name: "Menlo", size: 10)
        let ctFont = Self.coreTextFont(font)
        return Self.measureText(text, font: ctFont)
    }

    private nonisolated static func measureText(_ text: String, font: CTFont) -> Double {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        return ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Build a CoreText font from a ``MiniWindowFont`` (name/size + bold/italic
    /// traits), falling back to a monospaced face when the named family is
    /// unavailable so width measurement stays stable.
    nonisolated static func coreTextFont(_ font: MiniWindowFont) -> CTFont {
        let size = CGFloat(font.size > 0 ? font.size : 10)
        let base = CTFontCreateWithName((font.name.isEmpty ? "Menlo" : font.name) as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if font.bold { traits.insert(.traitBold) }
        if font.italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
              let adjusted = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits)
        else { return base }
        return adjusted
    }

    // MARK: - Scene mutation helpers

    /// Read-modify-write a window's scene (no-op if it doesn't exist), marking it
    /// dirty for the end-of-run flush.
    nonisolated func updateMiniWindow(_ name: String, _ body: (inout MiniWindowScene) -> Void) {
        guard var scene = miniWindows[name] else { return }
        body(&scene)
        miniWindows[name] = scene
        miniWindowsDirty.insert(name)
    }

    /// Append a draw command, starting a fresh frame on the first draw of a run
    /// (clears the prior frame's commands + hotspots). No-op for an unknown
    /// window (the plugin must `WindowCreate` first, as in MUSHclient).
    nonisolated func appendMiniWindowCommand(_ name: String, _ command: MiniWindowCommand) {
        guard miniWindows[name] != nil else { return }
        beginMiniWindowFrame(name)
        updateMiniWindow(name) { $0.commands.append(command) }
    }

    /// Clear the prior frame's commands + hotspots the first time a window is
    /// drawn/hotspotted in a run, so a redraw pass replaces wholesale.
    nonisolated func beginMiniWindowFrame(_ name: String) {
        guard !miniWindowFramePainted.contains(name) else { return }
        miniWindowFramePainted.insert(name)
        updateMiniWindow(name) {
            $0.commands.removeAll(keepingCapacity: true)
            $0.pixels.removeAll(keepingCapacity: true)
            $0.hotspots.removeAll(keepingCapacity: true)
        }
    }
}

struct MiniWindowPointerState: Equatable {
    var currentX: Int = 0
    var currentY: Int = 0
    var downX: Int = 0
    var downY: Int = 0
    var hotspotID: String = ""
    var downHotspotID: String = ""
}

extension LuaRuntime {
    nonisolated func recordMiniWindowEvent(_ event: MiniWindowEvent) {
        var state = miniWindowPointerStates[event.windowName] ?? MiniWindowPointerState()
        state.currentX = event.x
        state.currentY = event.y
        state.hotspotID = event.hotspotID
        if event.kind == .mouseDown {
            state.downX = event.x
            state.downY = event.y
            state.downHotspotID = event.hotspotID
        }
        miniWindowPointerStates[event.windowName] = state
    }
}
