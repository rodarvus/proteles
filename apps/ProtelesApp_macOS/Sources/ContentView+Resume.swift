import MudCore
import MudUI
import SwiftUI

/// Launch flow + session-resume (#42, auto-update Phase 2 "client-side
/// copyover"). Split out of `ContentView.swift` to keep that file/struct under
/// the size budget. Client-side copyover here = a *framed fast reconnect* (not
/// socket preservation): on a launch that consumed a fresh resume breadcrumb we
/// reopen the world, restore scrollback (seeded in `ProtelesApp.init`), connect,
/// and show a "Reconnecting…" pill instead of a cold start.
extension ContentView {
    /// First-launch + auto/resume connect. Driven by `.task { await launch() }`.
    func launch() async {
        await worlds.load()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.hasLaunchedKey) {
            defaults.set(true, forKey: Self.hasLaunchedKey)
            openWindow(id: ProtelesApp.worldsWindowID)
            return
        }

        // Resuming after a restart (#42): show the banner and connect even if
        // autoconnect is off — we were connected when the process restarted.
        if let resumeToken {
            resumeBanner = resumeToken.wasUpdated(runningVersion: MudCore.version)
                ? "Updated to \(MudCore.version) — reconnecting…"
                : "Reconnecting…"
        }
        if let active = worlds.activeProfile, active.autoconnect || resumeToken != nil {
            ProtelesApp.logContext.worldName = active.name
            await scripts.load(forProfile: active.id)
            try? await session.connect(
                to: active.endpoint,
                autologin: worlds.autologinPlan(for: active)
            )
        }
    }

    /// Mirror a network-state change into the status bar, and — on connect —
    /// clear the resume banner and write the resume breadcrumb so a restart while
    /// connected resumes this world (#42).
    func noteConnection(_ networkState: NetworkConnection.State) {
        connectionState = Self.map(networkState)
        guard case .connected = networkState else { return }
        resumeBanner = nil
        writeResumeToken()
    }

    /// (Re)write the resume breadcrumb for the active world while connected (#42).
    /// Called on connect *and* on a heartbeat so the token stays within its
    /// freshness window through a long session — otherwise a session online
    /// longer than the window wouldn't resume after an update.
    func writeResumeToken() {
        guard connectionState == .connected, let id = worlds.activeProfile?.id else { return }
        try? resumeStore?.write(
            ResumeToken(worldID: id, appVersion: MudCore.version, stamp: Date())
        )
    }

    /// Heartbeat that keeps the resume breadcrumb fresh (every 60 s, well inside
    /// the 120 s freshness window) for as long as the connection is up (#42).
    func refreshResumeTokenLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            writeResumeToken()
        }
    }

    /// The "Updated to vX — reconnecting…" / "Reconnecting…" pill shown at the
    /// top while a post-restart reconnect is in flight (#42). Softens the
    /// cold-restart feel; cleared the moment the connection comes up.
    @ViewBuilder
    var resumeBannerView: some View {
        if let resumeBanner {
            Text(resumeBanner)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.25)))
                .shadow(radius: 3, y: 1)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
