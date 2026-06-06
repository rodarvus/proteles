public extension ScriptEngine {
    /// Report the live output-view pixel size, surfaced to plugins via
    /// `GetInfo(280/281)` (#30). Forwards to the Lua runtime.
    func setOutputGeometry(width: Int, height: Int) async {
        await runtime.setOutputGeometry(width: width, height: height)
    }
}
