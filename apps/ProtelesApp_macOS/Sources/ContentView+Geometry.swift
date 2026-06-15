import CoreGraphics
import MudCore
import MudOutputView_macOS

extension ContentView {
    /// Push the main output view's pixel size to the session so a plugin's
    /// `GetInfo(280/281)` reflects the real window instead of a hardcoded
    /// default (#30), plus the character grid for NAWS (telnet window size).
    /// Driven by a `GeometryReader` `.task(id:)` in `gameColumn`, so it fires on
    /// first layout and every resize. (A font-only change re-reports on the next
    /// resize — the grid is recomputed from the current font here.)
    func reportOutputGeometry(_ size: CGSize) async {
        await session.setOutputGeometry(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded())
        )
        let grid = MudOutputView.characterGrid(
            for: size, fontName: outputFontName, fontSize: CGFloat(outputFontSize)
        )
        await session.setTerminalSize(columns: grid.columns, rows: grid.rows)
    }
}
