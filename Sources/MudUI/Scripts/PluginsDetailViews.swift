import MudCore
import SwiftUI

// Sidebar rows + detail panes + the compatibility-report views for the Plugins
// window (``PluginsView``), split out to keep that file within the length budget.

// MARK: - Rows

/// A built-in native plugin row: name + summary, with an enable toggle.
struct NativePluginRowView: View {
    let plugin: NativePluginRow
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill")
                .foregroundStyle(plugin.enabled ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name).lineLimit(1)
                Text(plugin.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { plugin.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }
}

/// A library plugin row: name + source kind, an enable toggle, and a marker for
/// a directory that no longer resolves to a plugin.
struct LibraryPluginRowView: View {
    let plugin: LibraryPluginRow
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: plugin.parsed ? "puzzlepiece.extension.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(plugin.parsed ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name).lineLimit(1)
                Text(plugin.parsed ? sourceLabel : "Files not found")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { plugin.enabled }, set: onToggle))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private var sourceLabel: String {
        switch plugin.origin {
        case .file: "From your Mac"
        case .url: "From a URL"
        }
    }
}

// MARK: - Detail content

/// The detail pane for a built-in core feature (mapper / S&D): what it is and
/// its key commands. Read-only — these are always-active native hosts.
struct BuiltInFeatureDetail: View {
    let feature: BuiltInFeatureRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(feature.name).font(.title2.weight(.semibold))
                    Text("Built in").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(feature.summary).font(.callout).foregroundStyle(.secondary)
                if !feature.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Commands").font(.headline)
                        ForEach(Array(feature.commands.enumerated()), id: \.offset) { _, command in
                            Text(command).font(.callout.monospaced())
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

/// The detail pane for a built-in native plugin: identity, overview, an
/// enabled badge, and the table of commands it provides.
struct NativePluginDetail: View {
    let plugin: NativePluginRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name).font(.title2.bold())
                    Text(metaLine).font(.caption).foregroundStyle(.secondary)
                }

                Label(
                    plugin.enabled ? "Enabled" : "Disabled",
                    systemImage: plugin.enabled ? "checkmark.circle.fill" : "pause.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(plugin.enabled ? Color.green : .secondary)

                if !plugin.help.overview.isEmpty {
                    Text(plugin.help.overview).font(.callout)
                } else if !plugin.summary.isEmpty {
                    Text(plugin.summary).font(.callout)
                }

                if !plugin.help.commands.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("COMMANDS").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(plugin.help.commands) { command in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(command.syntax)
                                    .font(.callout.monospaced())
                                    .textSelection(.enabled)
                                    .frame(minWidth: 120, alignment: .leading)
                                Text(command.summary)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var metaLine: String {
        var parts = ["Built-in"]
        if !plugin.author.isEmpty { parts.append(plugin.author) }
        if !plugin.version.isEmpty { parts.append("v\(plugin.version)") }
        return parts.joined(separator: " · ")
    }
}

/// The detail pane for a library plugin: identity, enabled state, its directory
/// (Reveal in Finder), the Update / Remove actions, and the compatibility
/// report.
struct LibraryPluginDetail: View {
    let plugin: LibraryPluginRow
    let report: PluginImportReport?
    let onReveal: () -> Void
    let onUpdate: () -> Void
    let onExport: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name).font(.title2.bold())
                    Text(sourceLine).font(.caption).foregroundStyle(.secondary)
                }
                Label(
                    plugin.enabled ? "Enabled" : "Disabled",
                    systemImage: plugin.enabled ? "checkmark.circle.fill" : "pause.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(plugin.enabled ? Color.green : .secondary)

                HStack(spacing: 10) {
                    Button("Reveal in Finder", systemImage: "folder", action: onReveal)
                    Button(updateLabel, systemImage: "arrow.triangle.2.circlepath", action: onUpdate)
                    Button("Export…", systemImage: "square.and.arrow.up", action: onExport)
                    Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !plugin.parsed {
                    Label(
                        "The plugin's files couldn't be found or parsed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCATION").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(plugin.directory.path).font(.callout.monospaced())
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Text("Lives in your Plugins folder — open it to hand-edit, or zip it to share.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let report {
                    ReportBody(report: report)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var sourceLine: String {
        switch plugin.origin {
        case .file: "Added from your Mac"
        case .url(let url): "From \(url)"
        }
    }

    private var updateLabel: String {
        switch plugin.origin {
        case .file: "Update from file…"
        case .url: "Refresh"
        }
    }
}

/// The add-confirm sheet: shows the compatibility report and offers Add / Cancel.
struct AddPluginReportSheet: View {
    let pending: PendingAdd
    let isAdding: Bool
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Plugin").font(.title2.bold())
            Text(pending.displayName)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            Divider()

            if let report = pending.report {
                ScrollView { ReportBody(report: report).padding(.trailing, 4) }
                    .frame(maxHeight: 360)
            } else {
                Label(
                    "These files aren't a recognisable MUSHclient plugin and can't be added.",
                    systemImage: "xmark.octagon.fill"
                )
                .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onAdd) {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending.report == nil || isAdding)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Verdict badge + plugin counts + the list of findings. Shared by the add
/// sheet and the library-plugin detail pane.
struct ReportBody: View {
    let report: PluginImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VerdictBadge(verdict: report.verdict)

            HStack(spacing: 18) {
                CountBadge(count: report.triggerCount, label: "Triggers")
                CountBadge(count: report.aliasCount, label: "Aliases")
                CountBadge(count: report.timerCount, label: "Timers")
            }

            if report.findings.isEmpty {
                Text("Works as it does in MUSHclient — nothing to set up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                        FindingRow(finding: finding)
                    }
                }
            }
        }
    }
}

struct VerdictBadge: View {
    let verdict: PluginImportReport.Verdict

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint, in: Capsule())
    }

    private var text: String {
        switch verdict {
        case .ready: "Ready to use"
        case .needsAttention: "Check setup"
        }
    }

    private var symbol: String {
        switch verdict {
        case .ready: "checkmark.seal.fill"
        case .needsAttention: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch verdict {
        case .ready: .green
        case .needsAttention: .orange
        }
    }
}

struct CountBadge: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FindingRow: View {
    let finding: PluginImportReport.Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(finding.message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch finding.severity {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch finding.severity {
        case .info: .secondary
        case .warning: .orange
        }
    }
}
