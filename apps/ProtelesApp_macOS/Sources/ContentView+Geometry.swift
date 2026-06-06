import CoreGraphics
import MudCore

extension ContentView {
    /// Push the main output view's pixel size to the session so a plugin's
    /// `GetInfo(280/281)` reflects the real window instead of a hardcoded
    /// default (#30). Driven by a `GeometryReader` `.task(id:)` in `gameColumn`,
    /// so it fires on first layout and on every resize.
    func reportOutputGeometry(_ size: CGSize) async {
        await session.setOutputGeometry(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
    }
}
