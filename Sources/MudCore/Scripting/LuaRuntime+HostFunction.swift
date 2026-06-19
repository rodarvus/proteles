import Foundation

extension LuaRuntime {
    /// The `proteles.*` functions exposed to scripts; the rawValue is the
    /// closure upvalue the C dispatcher routes on. Module-internal so the
    /// host-dispatch extension can switch on it. Lives in its own file (the
    /// case list keeps growing) so ``LuaRuntime`` stays within the file budget.
    enum HostFunction: Int32 {
        case send = 1
        case sendNoEcho
        case execute
        case echo
        case note
        case onEvent
        case raiseEvent
        case onBroadcast
        case broadcast
        case export
        case call
        case getVar
        case setVar
        case deleteVar
        case info
        case pluginID
        case getPluginVar
        case varList
        case compileChunk
        case moduleSource
        case sendGMCP
        case isConnected
        case jsonDecode
        case jsonEncode
        case echoAard, echoAnsi, simulate
        case colourNote, hyperlink, mapperCall, chatCapture
        case colourNameToRGB, rgbColourToName
        case sqliteAllowed
        case mapperMergeSQL
        case publish
        case enableTrigger, enableTimer, enableGroup, doAfter
        case addTrigger, setTriggerGroup, enableAlias, removeTrigger, monotonic, addAlias
        case setTriggerOption
        case notify
        case button
        case fileExists, makeDirectory, reloadPlugin
        case aardwolfTelnet
        case readFile, writeFile
        case dialog, accelerator, http
        case clipboardGet, clipboardSet
        case databaseDir
        case isPluginInstalled
        case sndCall
        case playSound
        case speak
        // MUSHclient miniwindow surface (see LuaRuntime+MiniWindow.swift). The
        // draw/lifecycle calls mutate the runtime's retained scene state; the
        // *Info/*Width calls are synchronous queries that return a value.
        case windowCreate, windowShow, windowDelete, windowResize, windowPosition
        case windowRectOp, windowText, windowLine, windowSetPixel, windowFont
        case windowTextWidth, windowInfo, windowFontInfo
        case windowAddHotspot, windowDeleteHotspot, windowDeleteAllHotspots
        case windowMoveHotspot, windowHotspotInfo
        case windowDragHandler, windowScrollwheelHandler, windowMenu
        case windowLoadImage, windowDrawImage, windowImageInfo
        case windowCircleOp, windowGradient, windowPolygon, windowArc, windowBezier
    }
}
