import AppKit
import MudCore
import MudUI
import SwiftUI

/// A single panel torn out of the dock into its own macOS window (UI revamp,
/// detachable windows). Renders the same live view as the docked panel — the
/// shared `@Observable` models are reference types, so the window stays in sync.
/// Closing the window drops it from ``LayoutStore/detached`` (`onDisappear`); a
/// re-dock button returns it to the dock. If the panel is re-docked or hidden
/// elsewhere (Panels menu), the window dismisses itself.
struct DetachedPanelWindow: View {
    let kind: PanelKind
    let session: SessionController
    let layout: LayoutStore
    let chat: ChatModel
    let map: MapPanelModel
    let asciiMap: MapModel
    let snd: SnDPanelModel
    let help: HelpPanelModel
    let levels: LevelDBPanelModel
    let scripts: ScriptsModel

    @Environment(\.dismiss) private var dismiss
    @State private var gmcp = GMCPState()

    var body: some View {
        content
            .frame(minWidth: 280, minHeight: 220)
            // Float above the main window so a torn-out panel stays visible even
            // when the main Proteles window has focus (SwiftUI's .windowLevel is
            // macOS 15+, so reach the NSWindow directly).
            .background(WindowAccessor { $0.level = .floating })
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        layout.redock(kind)
                        dismiss()
                    } label: {
                        Label("Re-dock", systemImage: "rectangle.portrait.and.arrow.forward")
                    }
                    .help("Return \(kind.title) to the main window")
                }
            }
            .task {
                // Only the Character panel needs live GMCP; cheap to always run.
                for await snapshot in await session.gmcpState.subscribe() {
                    gmcp = snapshot
                }
            }
            .onChange(of: layout.isDetached(kind)) { _, stillDetached in
                if !stillDetached { dismiss() } // re-docked/hidden from elsewhere
            }
            .onDisappear { layout.hideDetached(kind) }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .map: MapPanelView(model: map)
        case .asciiMap: MapView(model: asciiMap)
        case .channels: ChatView(model: chat)
        case .hunt: SearchAndDestroyPanelView(model: snd)
        case .info: InfoPanel(state: gmcp)
        case .help: HelpPanelView(model: help)
        case .levels: LevelDBPanelView(model: levels)
        case .commandBar: CommandBarView(scripts: scripts)
        case .output: EmptyView() // output isn't detachable (it's the main window)
        }
    }
}

/// Reaches the hosting `NSWindow` so we can apply AppKit-only configuration
/// (e.g. window level) not yet exposed by SwiftUI on macOS 14.
private struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { configure(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        DispatchQueue.main.async { if let window = nsView.window { configure(window) } }
    }
}
