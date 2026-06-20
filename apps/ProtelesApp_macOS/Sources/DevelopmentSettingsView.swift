import MudCore
import MudUI
import SwiftUI

/// Settings ▸ Development: the tools that used to live in the Debug and
/// Databases menus — session recording and the database import/reset
/// operations — plus the auto-record toggle (moved from Connection). These
/// are development/maintenance actions, not daily-play commands; a settings
/// tab keeps the menu bar calm without hiding them (DESIGN.md §3.5).
struct DevelopmentSettingsView: View {
    let session: SessionController
    let map: MapPanelModel
    let snd: SnDPanelModel
    let pluginDBs: PluginDatabasesModel

    @AppStorage("autoRecordSessions") private var autoRecordSessions = true
    @AppStorage(PerformanceDiagnosticsDefaults.key)
    private var performanceDiagnosticsMode = PerformanceDiagnosticsDefaults.defaultMode
    /// Feedback line for the manual recording buttons.
    @State private var recordingStatus: String?

    var body: some View {
        Form {
            Section("Session Recording") {
                Toggle("Record sessions automatically", isOn: $autoRecordSessions)
                Text("Save a replayable capture of each session locally (under "
                    + "Documents/Proteles/Recordings). Takes effect on the next "
                    + "connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Start Recording") { startRecording() }
                    Button("Stop Recording") { stopRecording() }
                }
                if let recordingStatus {
                    Text(recordingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Performance Diagnostics") {
                Picker("Recording detail", selection: $performanceDiagnosticsMode) {
                    ForEach(PerformanceProbe.Mode.allCases, id: \.rawValue) { mode in
                        Text(label(for: mode)).tag(mode.rawValue)
                    }
                }
                Text(description(for: selectedPerformanceMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Import Databases") {
                Button("Import Map Database…") { map.importDatabase() }
                Button("Import Search & Destroy Database…") { snd.requestImport() }
                Button("Import Inventory (dinv) Database…") { pluginDBs.importDinv() }
                Button("Import Leveling (leveldb) Database…") { pluginDBs.importLevelDB() }
                Text("Bring databases over from a MUSHclient install — or use "
                    + "File ▸ Import from MUSHclient… for everything at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Reset Databases (Testing)") {
                Button("Empty Map Database…", role: .destructive) { map.resetDatabase() }
                Button("Empty Search & Destroy Database…", role: .destructive) {
                    snd.requestReset()
                }
                Button("Delete Inventory (dinv) Database…", role: .destructive) {
                    pluginDBs.resetDinv()
                }
                Button("Delete Leveling (leveldb) Database…", role: .destructive) {
                    pluginDBs.resetLevelDB()
                }
                Text("Destructive — each asks for confirmation first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The former Diagnostics tab (crash/hang capture + reports),
            // folded in by the #35 settings review.
            DiagnosticsSections()
        }
        .formStyle(.grouped)
    }

    private func startRecording() {
        let session = session
        Task {
            do {
                let url = try SessionRecorder.defaultRecordingURL()
                try await session.startRecording(to: url)
                recordingStatus = "Recording to \(url.path)"
            } catch {
                recordingStatus = "Couldn't start recording: \(error.localizedDescription)"
            }
        }
    }

    private func stopRecording() {
        let session = session
        Task {
            await session.stopRecording()
            recordingStatus = "Recording stopped."
        }
    }

    private var selectedPerformanceMode: PerformanceProbe.Mode {
        PerformanceProbe.Mode(rawValue: performanceDiagnosticsMode) ?? .stallOnly
    }

    private func label(for mode: PerformanceProbe.Mode) -> String {
        switch mode {
        case .off: "Off"
        case .stallOnly: "Stall notes only"
        case .full: "Full attribution"
        }
    }

    private func description(for mode: PerformanceProbe.Mode) -> String {
        switch mode {
        case .off:
            "Do not add performance notes to session recordings."
        case .stallOnly:
            "Default for public builds. Records only UI-stall notes when the "
                + "main thread is visibly blocked."
        case .full:
            "Records phase timings, burst summaries, render health, and stall "
                + "attribution. Use this when collecting performance evidence."
        }
    }
}

enum PerformanceDiagnosticsDefaults {
    static let key = "performanceDiagnosticsMode"
    static let defaultMode = PerformanceProbe.Mode.stallOnly.rawValue
}
