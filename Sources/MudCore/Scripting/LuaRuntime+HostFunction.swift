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
        case compileChunk
        case moduleSource
        case sendGMCP
        case isConnected
        case jsonDecode
        case jsonEncode
        case echoAard, echoAnsi, simulate
        case colourNote, hyperlink, mapperCall, chatCapture
        case sqliteAllowed
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
    }
}
