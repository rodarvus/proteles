public extension SessionController {
    /// Report the live output-view pixel size so a plugin's `GetInfo(280/281)`
    /// reflects the real window instead of a hardcoded default (#30). The app
    /// calls this as the main output view resizes.
    func setOutputGeometry(width: Int, height: Int) async {
        await scriptEngine?.setOutputGeometry(width: width, height: height)
    }
}
