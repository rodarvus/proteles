import Foundation
import ImageIO

/// Phase 2–4 of the miniwindow surface: hotspots + mouse routing (Phase 2),
/// images (Phase 3), and the shape/gradient tail (Phase 4). Split from
/// `LuaRuntime+MiniWindow` (Phase 1 lifecycle/draw/queries) for the file budget.
extension LuaRuntime {
    /// Dispatch the non-Phase-1 `proteles.window*` calls. Returns a value for
    /// the query functions; `[]` otherwise.
    nonisolated func miniWindowExtraCall(
        _ function: HostFunction, _ name: String, _ arguments: [LuaValue]
    ) -> [LuaValue] {
        switch function {
        // Phase 2 — hotspots
        case .windowAddHotspot: addMiniWindowHotspot(name, arguments)
        case .windowDeleteHotspot: deleteMiniWindowHotspot(name, Self.argString(arguments, 1))
        case .windowDeleteAllHotspots: updateMiniWindow(name) { $0.hotspots.removeAll() }
        case .windowMoveHotspot: moveMiniWindowHotspot(name, arguments)
        case .windowDragHandler: installMiniWindowDragHandler(name, arguments)
        case .windowScrollwheelHandler: installMiniWindowScrollHandler(name, arguments)
        case .windowHotspotInfo: return [miniWindowHotspotInfoValue(name, arguments)]
        case .windowMenu: return [.nil] // no synchronous popup menu in the spike
        default: return miniWindowImageOrShapeCall(function, name, arguments)
        }
        return []
    }

    /// Image (Phase 3) + shape (Phase 4) dispatch, split from
    /// ``miniWindowExtraCall`` to keep each switch within the complexity budget.
    private nonisolated func miniWindowImageOrShapeCall(
        _ function: HostFunction, _ name: String, _ arguments: [LuaValue]
    ) -> [LuaValue] {
        switch function {
        case .windowLoadImage: loadMiniWindowImage(name, arguments)
        case .windowDrawImage: appendImageDraw(name, arguments)
        case .windowImageInfo: return [miniWindowImageInfoValue(name, arguments)]
        case .windowCircleOp: appendCircleOp(name, arguments)
        case .windowGradient: appendGradient(name, arguments)
        case .windowPolygon: appendPolygon(name, arguments)
        case .windowArc: appendArc(name, arguments)
        case .windowBezier: appendBezier(name, arguments)
        default: break
        }
        return []
    }

    // MARK: - Phase 2: hotspots (implemented in this phase)

    private nonisolated func addMiniWindowHotspot(_ name: String, _ arguments: [LuaValue]) {
        let hotspotID = Self.argString(arguments, 1)
        guard miniWindows[name] != nil, !hotspotID.isEmpty else { return }
        beginMiniWindowFrame(name)
        let hotspot = MiniWindowHotspot(
            id: hotspotID,
            left: Int(Self.argDouble(arguments, 2)),
            top: Int(Self.argDouble(arguments, 3)),
            right: Int(Self.argDouble(arguments, 4)),
            bottom: Int(Self.argDouble(arguments, 5)),
            mouseOver: Self.argString(arguments, 6),
            cancelMouseOver: Self.argString(arguments, 7),
            mouseDown: Self.argString(arguments, 8),
            cancelMouseDown: Self.argString(arguments, 9),
            mouseUp: Self.argString(arguments, 10),
            tooltip: Self.argString(arguments, 11),
            cursor: Int(Self.argDouble(arguments, 12)),
            flags: Int(Self.argDouble(arguments, 13))
        )
        updateMiniWindow(name) { scene in
            scene.hotspots.removeAll { $0.id == hotspotID }
            scene.hotspots.append(hotspot)
        }
    }

    private nonisolated func deleteMiniWindowHotspot(_ name: String, _ hotspotID: String) {
        updateMiniWindow(name) { $0.hotspots.removeAll { $0.id == hotspotID } }
    }

    private nonisolated func moveMiniWindowHotspot(_ name: String, _ arguments: [LuaValue]) {
        let hotspotID = Self.argString(arguments, 1)
        updateMiniWindow(name) { scene in
            guard let index = scene.hotspots.firstIndex(where: { $0.id == hotspotID }) else { return }
            scene.hotspots[index].left = Int(Self.argDouble(arguments, 2))
            scene.hotspots[index].top = Int(Self.argDouble(arguments, 3))
            scene.hotspots[index].right = Int(Self.argDouble(arguments, 4))
            scene.hotspots[index].bottom = Int(Self.argDouble(arguments, 5))
        }
    }

    /// `WindowDragHandler(name, hotspotID, moveCallback, releaseCallback, flags)`
    /// — attach drag callbacks to an existing hotspot.
    private nonisolated func installMiniWindowDragHandler(_ name: String, _ arguments: [LuaValue]) {
        let hotspotID = Self.argString(arguments, 1)
        updateMiniWindow(name) { scene in
            guard let index = scene.hotspots.firstIndex(where: { $0.id == hotspotID }) else { return }
            scene.hotspots[index].dragMove = Self.argString(arguments, 2)
            scene.hotspots[index].dragRelease = Self.argString(arguments, 3)
            scene.hotspots[index].dragFlags = Int(Self.argDouble(arguments, 4))
        }
    }

    /// `WindowScrollwheelHandler(name, hotspotID, moveCallback)`.
    private nonisolated func installMiniWindowScrollHandler(_ name: String, _ arguments: [LuaValue]) {
        let hotspotID = Self.argString(arguments, 1)
        updateMiniWindow(name) { scene in
            guard let index = scene.hotspots.firstIndex(where: { $0.id == hotspotID }) else { return }
            scene.hotspots[index].scrollwheel = Self.argString(arguments, 2)
        }
    }

    /// `WindowHotspotInfo(name, hotspotID, infoType)` — MUSHclient hotspot
    /// metadata: rect, callback names, tooltip, cursor, flags, and drag state.
    private nonisolated func miniWindowHotspotInfoValue(_ name: String, _ arguments: [LuaValue]) -> LuaValue {
        let hotspotID = Self.argString(arguments, 1)
        guard let hotspot = miniWindows[name]?.hotspots.first(where: { $0.id == hotspotID })
        else { return .nil }
        let info = Int(Self.argDouble(arguments, 2))
        if let value = miniWindowHotspotBoundsInfoValue(hotspot, info) { return value }
        if let value = miniWindowHotspotCallbackInfoValue(hotspot, info) { return value }
        if let value = miniWindowHotspotDragInfoValue(hotspot, info) { return value }
        return .nil
    }

    private nonisolated func miniWindowHotspotBoundsInfoValue(
        _ hotspot: MiniWindowHotspot,
        _ info: Int
    ) -> LuaValue? {
        switch info {
        case 1: .number(Double(hotspot.left))
        case 2: .number(Double(hotspot.top))
        case 3: .number(Double(hotspot.right))
        case 4: .number(Double(hotspot.bottom))
        default: nil
        }
    }

    private nonisolated func miniWindowHotspotCallbackInfoValue(
        _ hotspot: MiniWindowHotspot,
        _ info: Int
    ) -> LuaValue? {
        switch info {
        case 5: .string(hotspot.mouseOver)
        case 6: .string(hotspot.cancelMouseOver)
        case 7: .string(hotspot.mouseDown)
        case 8: .string(hotspot.cancelMouseDown)
        case 9: .string(hotspot.mouseUp)
        case 10: .string(hotspot.tooltip)
        case 11: .number(Double(hotspot.cursor))
        case 12: .number(Double(hotspot.flags))
        default: nil
        }
    }

    private nonisolated func miniWindowHotspotDragInfoValue(
        _ hotspot: MiniWindowHotspot,
        _ info: Int
    ) -> LuaValue? {
        switch info {
        case 13: .string(hotspot.dragMove)
        case 14: .string(hotspot.dragRelease)
        case 15: .number(Double(hotspot.dragFlags))
        default: nil
        }
    }

    // MARK: - Phase 3: images

    /// `proteles.windowLoadImage(name, imageID, source, isMemory)` — load image
    /// bytes for the owning plugin. `isMemory` true → `source` is the in-memory
    /// buffer (base64 from the shim, or raw if NUL-free); false → a file path
    /// read sandbox-gated. Records a `.loadMiniWindowImage` effect the session
    /// forwards to the renderer's image store. Bytes travel once, here — draw
    /// commands then reference only the id.
    private nonisolated func loadMiniWindowImage(_ name: String, _ arguments: [LuaValue]) {
        let imageID = Self.argString(arguments, 1)
        guard !imageID.isEmpty else { return }
        let source = Self.argString(arguments, 2)
        let isMemory = Self.argBool(arguments, 3)
        let data: Data? = isMemory
            ? (Data(base64Encoded: source) ?? source.data(using: .utf8))
            : readFileData(source)
        guard let data, !data.isEmpty else { return }
        let metadata = Self.imageMetadata(id: imageID, data: data)
        updateMiniWindow(name) { scene in
            scene.images[imageID] = metadata
        }
        effects.append(.loadMiniWindowImage(pluginID: pluginContext.pluginID, imageID: imageID, data: data))
    }

    private nonisolated func miniWindowImageInfoValue(_ name: String, _ arguments: [LuaValue]) -> LuaValue {
        let imageID = Self.argString(arguments, 1)
        guard let image = miniWindows[name]?.images[imageID] else { return .nil }
        switch Int(Self.argDouble(arguments, 2)) {
        case 2: return .number(Double(image.width))
        case 3: return .number(Double(image.height))
        default: return .nil
        }
    }

    private nonisolated static func imageMetadata(id: String, data: Data) -> MiniWindowImageInfo {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return MiniWindowImageInfo(id: id, width: 0, height: 0)
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return MiniWindowImageInfo(id: id, width: width, height: height)
    }

    private nonisolated func appendImageDraw(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .image(
            imageID: Self.argString(arguments, 1),
            left: Int(Self.argDouble(arguments, 2)),
            top: Int(Self.argDouble(arguments, 3)),
            right: Int(Self.argDouble(arguments, 4)),
            bottom: Int(Self.argDouble(arguments, 5)),
            mode: arguments.count > 6 ? Int(Self.argDouble(arguments, 6)) : 1,
            opacity: 1,
            srcLeft: Int(Self.argDouble(arguments, 7)),
            srcTop: Int(Self.argDouble(arguments, 8)),
            srcRight: Int(Self.argDouble(arguments, 9)),
            srcBottom: Int(Self.argDouble(arguments, 10))
        ))
    }

    // MARK: - Phase 4: shapes

    private nonisolated func appendCircleOp(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .circle(
            action: Int(Self.argDouble(arguments, 1)),
            left: Int(Self.argDouble(arguments, 2)),
            top: Int(Self.argDouble(arguments, 3)),
            right: Int(Self.argDouble(arguments, 4)),
            bottom: Int(Self.argDouble(arguments, 5)),
            penColour: Int(Self.argDouble(arguments, 6)),
            penStyle: Int(Self.argDouble(arguments, 7)),
            penWidth: max(1, Int(Self.argDouble(arguments, 8))),
            brushColour: Int(Self.argDouble(arguments, 9)),
            brushStyle: Int(Self.argDouble(arguments, 10)),
            extra1: Int(Self.argDouble(arguments, 11)),
            extra2: Int(Self.argDouble(arguments, 12))
        ))
    }

    private nonisolated func appendGradient(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .gradient(
            left: Int(Self.argDouble(arguments, 1)),
            top: Int(Self.argDouble(arguments, 2)),
            right: Int(Self.argDouble(arguments, 3)),
            bottom: Int(Self.argDouble(arguments, 4)),
            startColour: Int(Self.argDouble(arguments, 5)),
            endColour: Int(Self.argDouble(arguments, 6)),
            mode: Int(Self.argDouble(arguments, 7))
        ))
    }

    private nonisolated func appendPolygon(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .polygon(
            points: Self.parsePoints(Self.argString(arguments, 1)),
            penColour: Int(Self.argDouble(arguments, 2)),
            penStyle: Int(Self.argDouble(arguments, 3)),
            penWidth: max(1, Int(Self.argDouble(arguments, 4))),
            brushColour: Int(Self.argDouble(arguments, 5)),
            brushStyle: Int(Self.argDouble(arguments, 6)),
            close: Self.argBool(arguments, 7),
            winding: Self.argBool(arguments, 8)
        ))
    }

    private nonisolated func appendArc(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .arc(
            left: Int(Self.argDouble(arguments, 1)),
            top: Int(Self.argDouble(arguments, 2)),
            right: Int(Self.argDouble(arguments, 3)),
            bottom: Int(Self.argDouble(arguments, 4)),
            x1: Int(Self.argDouble(arguments, 5)),
            y1: Int(Self.argDouble(arguments, 6)),
            x2: Int(Self.argDouble(arguments, 7)),
            y2: Int(Self.argDouble(arguments, 8)),
            colour: Int(Self.argDouble(arguments, 9)),
            penStyle: Int(Self.argDouble(arguments, 10)),
            penWidth: max(1, Int(Self.argDouble(arguments, 11)))
        ))
    }

    private nonisolated func appendBezier(_ name: String, _ arguments: [LuaValue]) {
        appendMiniWindowCommand(name, .bezier(
            points: Self.parsePoints(Self.argString(arguments, 1)),
            colour: Int(Self.argDouble(arguments, 2)),
            penStyle: Int(Self.argDouble(arguments, 3)),
            penWidth: max(1, Int(Self.argDouble(arguments, 4)))
        ))
    }

    /// Parse a MUSHclient point list ("x1,y1,x2,y2,…") into `MWPoint`s.
    nonisolated static func parsePoints(_ text: String) -> [MWPoint] {
        let numbers = text.split { $0 == "," || $0 == " " }.compactMap { Double($0) }
        var points: [MWPoint] = []
        var index = 0
        while index + 1 < numbers.count {
            points.append(MWPoint(x: numbers[index], y: numbers[index + 1]))
            index += 2
        }
        return points
    }
}
