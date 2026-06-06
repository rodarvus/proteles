import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle's updater for the app (#23 auto-updater, Phase 1).
///
/// The feed URL and EdDSA public key live in `Info.plist` (`SUFeedURL` /
/// `SUPublicEDKey`); the private signing key lives only in the release machine's
/// login keychain (never committed). **Interim:** the feed is on GitHub Pages
/// until `proteles.net` is registered — see
/// `docs/plans/AUTOUPDATE_AND_COPYOVER.md`.
///
/// Phase 1 is *install-on-quit + manual check + background daily check*. The
/// mid-combat "update now" guard (gate on `char.status` `state`/`pos`) is Phase 2.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item can disable
    /// itself while a check is already in flight.
    @Published var canCheck = true

    init() {
        // `startingUpdater: true` starts Sparkle at launch (the recommended
        // pattern); background checks honour `SUEnableAutomaticChecks`.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    /// User-initiated check (the "Check for Updates…" menu item).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
