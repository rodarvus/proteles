import MudCore
import MudOutputView_macOS
import MudUI
import SwiftUI

@main
struct ProtelesApp: App {
    var body: some Scene {
        WindowGroup("Proteles") {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .navigationTitle("Proteles")
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Proteles") {
                    NSApp.orderFrontStandardAboutPanel(
                        options: [
                            .applicationVersion: MudCore.version,
                            .credits: NSAttributedString(
                                string: "A native Aardwolf MUD client for macOS.",
                                attributes: [.font: NSFont.systemFont(ofSize: 11)]
                            )
                        ]
                    )
                }
            }
        }
    }
}
