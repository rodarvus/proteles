import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle's updater for the app (#23 auto-updater).
///
/// The feed URL and EdDSA public key live in `Info.plist` (`SUFeedURL` /
/// `SUPublicEDKey`); the private signing key lives only in the release machine's
/// login keychain (never committed). **Interim:** the feed is on GitHub Pages
/// until `proteles.net` is registered — see
/// `docs/plans/AUTOUPDATE_AND_COPYOVER.md`.
///
/// Phase 2b mid-combat guard: `safeToInterrupt` mirrors live `char.status`
/// (updated from the GMCP stream in `ContentView`); a **background** scheduled
/// check is deferred while it's false (fighting / running / note-mode / engaged),
/// so an update prompt never pops mid-combat. A user-initiated "Check for
/// Updates…" always proceeds — the user asked.
@MainActor
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item can disable
    /// itself while a check is already in flight.
    @Published var canCheck = true

    /// Whether it's currently OK to interrupt with a background update prompt
    /// (#42). Driven by `ContentView` from `char.status`; defaults to true so a
    /// disconnected/idle client still updates.
    var safeToInterrupt = true

    override init() {
        super.init()
        // `startingUpdater: true` starts Sparkle at launch (the recommended
        // pattern); background checks honour `SUEnableAutomaticChecks`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    /// User-initiated check (the "Check for Updates…" menu item).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    /// Gate **background** scheduled checks on the mid-combat guard; allow
    /// user-initiated checks always. Throwing defers the check (Sparkle retries
    /// on the next scheduled interval). Sparkle invokes delegate methods on the
    /// main thread, so reading the main-actor flag via `assumeIsolated` is safe.
    nonisolated func updater(_: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground else { return }
        let safe = MainActor.assumeIsolated { safeToInterrupt }
        guard !safe else { return }
        throw NSError(
            domain: "com.proteles.Updater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Deferred: not a safe moment to interrupt."]
        )
    }
}
