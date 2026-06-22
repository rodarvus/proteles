import AppKit
import MudCore

extension ContentView {
    /// Gate a plugin's `OpenBrowser(url)` behind a per-plugin confirmation. A
    /// plugin reaching out to the browser is outward-facing, so the first time a
    /// given plugin asks we prompt (Allow Once / Always Allow / Don't Allow) and
    /// remember an "Always" grant in `UserDefaults`. The shim already restricted
    /// the URL to http/https/mailto. Lives in its own file so `ContentView` stays
    /// within the file- and type-body-length budgets.
    @MainActor
    static func handleOpenBrowser(_ request: OpenBrowserRequest) {
        guard let url = URL(string: request.url) else { return }
        let key = "openBrowser.alwaysAllowed"
        var allowed = Set(
            (UserDefaults.standard.string(forKey: key) ?? "")
                .split(separator: "\n").map(String.init)
        )
        if !allowed.contains(request.pluginID) {
            let name = request.pluginName.isEmpty ? request.pluginID : request.pluginName
            let alert = NSAlert()
            alert.messageText = "Allow “\(name)” to open a web link?"
            alert.informativeText = request.url
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Always Allow")
            alert.addButton(withTitle: "Don’t Allow")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                break // allow once
            case .alertSecondButtonReturn:
                allowed.insert(request.pluginID)
                UserDefaults.standard.set(allowed.joined(separator: "\n"), forKey: key)
            default:
                return // don't allow
            }
        }
        NSWorkspace.shared.open(url)
    }
}
