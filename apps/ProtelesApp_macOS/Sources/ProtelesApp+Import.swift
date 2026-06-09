import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// MUSHclient-import entry point (File ▸ Import from MUSHclient…). Split from
/// `ProtelesApp` to keep that file within the line budget.
extension ProtelesApp {
    /// The About-panel credits blurb.
    static let aboutCredits = NSAttributedString(
        string: "A native Aardwolf MUD client for macOS.\n"
            + "Faithful colours, native mapper, built-in scripting.",
        attributes: [.font: NSFont.systemFont(ofSize: 11)]
    )

    /// Drives the import review sheet's presentation (shown whenever the flow is
    /// past `.idle`; dismissing resets it).
    var importSheetBinding: Binding<Bool> {
        Binding(
            get: { importModel.phase != .idle },
            set: { if !$0 { importModel.reset() } }
        )
    }

    /// Prompt for the MUSHclient folder (or a `.zip` of it) and start the scan;
    /// reload the world list after a successful import.
    func presentMUSHclientImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip]
        panel.prompt = "Scan"
        panel.message = "Choose your MUSHclient folder (or a .zip of it)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importModel.onImported = { [worlds] in Task { await worlds.load() } }
        importModel.beginScan(at: url)
    }
}
