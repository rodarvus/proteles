#if canImport(MetricKit)
    import AppKit
    import MudCore
    import SwiftUI

    /// Settings ▸ Development's crash-diagnostics sections (the former
    /// Diagnostics tab, folded in by the #35 review — recording, databases,
    /// and crash capture are one developer-flavoured audience): the opt-in
    /// crash/hang capture toggle and the list of captured reports, with
    /// per-report copy / reveal / delete. All on-device; the copy action
    /// produces a content-free summary (no game text or recording is ever
    /// included automatically). Plain `Section`s, embedded in Development's
    /// `Form`.
    struct DiagnosticsSections: View {
        @AppStorage(DiagnosticsController.enabledKey) private var enabled = false
        @State private var reports: [DiagnosticReport] = []

        var body: some View {
            Section("Crash Diagnostics") {
                Toggle("Capture crash & hang diagnostics", isOn: $enabled)
                    .help("Opt-in, on-device only — nothing is ever sent anywhere")
                Text("""
                Opt-in, on-device only (Apple MetricKit) — nothing is ever sent anywhere. \
                Reports arrive on the next launch after an event and hold a call stack plus \
                app/OS version; no game text or passwords. Stored under Application Support; \
                the newest 20 are kept.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear(perform: refresh)
            .onChange(of: enabled) { _, isOn in
                DiagnosticsController.shared.setEnabled(isOn)
                refresh()
            }
            Section("Captured reports") {
                if reports.isEmpty {
                    Text(enabled ? "None captured." : "Capture is off.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(reports) { report in
                        DiagnosticRow(report: report) { delete(report) }
                    }
                    Button("Delete All", role: .destructive) {
                        DiagnosticsController.shared.deleteAll()
                        refresh()
                    }
                }
            }
        }

        private func refresh() {
            reports = DiagnosticsController.shared.reports()
        }

        private func delete(_ report: DiagnosticReport) {
            DiagnosticsController.shared.delete(report)
            refresh()
        }
    }

    /// One captured report: headline, when, the session it occurred during (a
    /// pointer only), and copy / reveal / delete actions.
    private struct DiagnosticRow: View {
        let report: DiagnosticReport
        let onDelete: () -> Void
        @State private var copied = false

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(report.summary.headline).font(.callout.weight(.medium))
                Text(report.capturedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                if let recording = DiagnosticsController.shared.correlatedRecording(for: report) {
                    Text("During \(recording)").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button(copied ? "Copied ✓" : "Copy summary") { copySummary() }
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([report.url]) }
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .buttonStyle(.borderless).font(.caption)
            }
            .padding(.vertical, 2)
        }

        private func copySummary() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(DiagnosticsController.shared.summaryText(for: report), forType: .string)
            copied = true
        }
    }
#endif
