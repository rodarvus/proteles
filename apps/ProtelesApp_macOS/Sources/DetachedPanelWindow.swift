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
    let consider: ConsiderPanelModel
    let help: HelpPanelModel
    let levels: LevelDBPanelModel
    let scripts: ScriptsModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow
    /// Reference model, like ContentView's (#61): the task writes `.state`,
    /// only the Character/Group panel bodies read it — per-GMCP updates never
    /// re-diff this window's root (toolbar, chrome, the other panel kinds).
    @State private var gmcp = GMCPStateModel()

    var body: some View {
        content
            .frame(minWidth: 280, minHeight: 220)
            // Float above the *main Proteles window* while Proteles is active, but
            // drop to the normal level when Proteles is in the background so a
            // torn-out panel never sits on top of OTHER apps (GH #36). Driving the
            // NSWindow level off `controlActiveState` is reaction-free vs. AppKit
            // notifications; SwiftUI's `.windowLevel` is macOS 15+, so we reach the
            // NSWindow directly.
            .background(WindowLevelAccessor(
                level: controlActiveState == .inactive ? .normal : .floating
            ))
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
                    PerformanceProbe.shared.measure(
                        "ui.detached-gmcp-model.apply",
                        events: 1,
                        thresholdMS: 50
                    ) {
                        gmcp.state = snapshot
                    }
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
        case .consider: ConsiderPanelView(model: consider)
        case .info: InfoPanel(state: gmcp)
        case .group: GroupPanel(state: gmcp, onCommand: { command in
                Task { try? await session.send(command) }
            })
        case .help: HelpPanelView(model: help)
        case .levels: LevelDBPanelView(model: levels)
        case .commandBar: CommandBarView(scripts: scripts, onOpenEditor: {
                openWindow(id: ProtelesApp.scriptsWindowID)
                scripts.requestButtonsTab()
            })
        case .output: EmptyView() // output isn't detachable (it's the main window)
        }
    }
}

/// Reaches the hosting `NSWindow` to set its level (not exposed by SwiftUI on
/// macOS 14). Re-applied whenever `level` changes — e.g. as the app activates or
/// deactivates — so a detached panel floats above the main window only while
/// Proteles is frontmost (GH #36).
private struct WindowLevelAccessor: NSViewRepresentable {
    let level: NSWindow.Level

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        let level = level
        DispatchQueue.main.async { view.window?.level = level }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        let level = level
        DispatchQueue.main.async { nsView.window?.level = level }
    }
}
