#if canImport(MetricKit)
    import Foundation
    import MetricKit
    import MudCore

    /// Owns the opt-in MetricKit crash/hang capture. MetricKit delivers an
    /// `MXDiagnosticPayload` on the *next launch* after an event (not in real
    /// time), aggregated over up to ~24h; we persist each payload's JSON via the
    /// pure ``DiagnosticsStore`` so the Diagnostics settings pane can surface it.
    ///
    /// Strictly opt-in (default off) and on-device only: we only register as a
    /// MetricKit subscriber while the user has enabled it, and `didReceive`
    /// re-checks the flag before writing anything. Nothing is ever sent anywhere.
    @MainActor
    final class DiagnosticsController: NSObject, MXMetricManagerSubscriber {
        static let shared = DiagnosticsController()

        /// The `@AppStorage`/UserDefaults key the Settings toggle drives.
        nonisolated static let enabledKey = "diagnostics.enabled"

        private let store = try? DiagnosticsStore()
        private var subscribed = false

        /// Register/unregister the MetricKit subscriber to match the toggle.
        func setEnabled(_ enabled: Bool) {
            if enabled, !subscribed {
                MXMetricManager.shared.add(self)
                subscribed = true
            } else if !enabled, subscribed {
                MXMetricManager.shared.remove(self)
                subscribed = false
            }
        }

        // MARK: MXMetricManagerSubscriber

        /// Performance metrics — not crash data; we don't persist these.
        /// `nonisolated`: MetricKit delivers on its own queue, not the main actor.
        nonisolated func didReceive(_: [MXMetricPayload]) {}

        /// Crash / hang / CPU / disk-write diagnostics. Persist each payload's
        /// JSON, guarded by the live opt-in flag (belt-and-braces over `setEnabled`).
        /// `nonisolated` (off-main delivery); only touches the Sendable store +
        /// UserDefaults, so no main-actor state is involved.
        nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
            guard UserDefaults.standard.bool(forKey: Self.enabledKey), let store else { return }
            for payload in payloads {
                try? store.save(payloadJSON: payload.jsonRepresentation())
            }
        }

        // MARK: UI helpers (read/manage stored reports)

        func reports() -> [DiagnosticReport] {
            store?.reports() ?? []
        }

        func delete(_ report: DiagnosticReport) {
            store?.delete(report)
        }

        func deleteAll() {
            store?.deleteAll()
        }

        func summaryText(for report: DiagnosticReport) -> String {
            store?.summaryText(for: report) ?? ""
        }

        /// The recording that was running when the diagnostic fired (a pointer
        /// only — we never auto-attach it; recordings carry MUD content + the
        /// autologin password and must be reviewed before sharing).
        func correlatedRecording(for report: DiagnosticReport) -> String? {
            guard let store,
                  let recordings = try? SessionRecorder.defaultRecordingURL().deletingLastPathComponent()
            else { return nil }
            return store.correlatedRecording(for: report, recordingsDirectory: recordings)
        }
    }
#endif
