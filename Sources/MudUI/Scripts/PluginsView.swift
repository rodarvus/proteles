import MudCore
import SwiftUI
#if os(macOS)
    import UniformTypeIdentifiers
#endif

/// The "Plugins" window: lists a world's installed MUSHclient `.xml`
/// plugins and runs a guided import that, before installing, shows a
/// compatibility report (what works, what doesn't) produced by
/// ``PluginImporter`` (PLAN.md §7.5).
///
/// Import starts in the user's Documents folder (where players keep
/// downloaded plugins), analyses the chosen file, and only copies it into
/// the world's plugins directory once the user confirms. Installing or
/// removing re-syncs the live session so the change applies immediately.
public struct PluginsView: View {
    @Bindable private var model: PluginsModel

    /// A file the user picked to import, paired with its analysis. Drives
    /// the report sheet. `nil` when no import is in progress.
    @State private var pendingImport: PendingImport?
    @State private var isInstalling = false

    public init(model: PluginsModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle("Plugins")
        .sheet(item: $pendingImport) { pending in
            ImportReportSheet(
                pending: pending,
                isInstalling: isInstalling,
                onInstall: { install(pending) },
                onCancel: { pendingImport = nil }
            )
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            if !model.nativePlugins.isEmpty {
                Section("Built-in") {
                    ForEach(model.nativePlugins) { plugin in
                        NativePluginRowView(plugin: plugin) { enabled in
                            Task { await model.setNativeEnabled(enabled, id: plugin.id) }
                        }
                        .tag(PluginSelection.native(plugin.id))
                    }
                }
            }
            Section("Installed") {
                ForEach(model.installed) { plugin in
                    PluginRow(plugin: plugin).tag(PluginSelection.imported(plugin.id))
                }
                if model.installed.isEmpty {
                    Text("Import a MUSHclient .xml plugin to add one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: beginImport) {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { await removeSelected() }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(model.selectedImportedURL == nil)
            }
        }
    }

    // MARK: - Detail

    private var selectedImportedPlugin: InstalledPlugin? {
        guard let url = model.selectedImportedURL else { return nil }
        return model.installed.first { $0.id == url }
    }

    @ViewBuilder
    private var detail: some View {
        if let native = model.selectedNative {
            NativePluginDetail(plugin: native)
        } else if let plugin = selectedImportedPlugin {
            InstalledPluginDetail(plugin: plugin, report: model.report(for: plugin.id))
        } else {
            ContentUnavailableView(
                "No Plugin Selected",
                systemImage: "puzzlepiece.extension",
                description: Text("Select a plugin to see what it does, or import a new one.")
            )
        }
    }

    // MARK: - Actions

    private func beginImport() {
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.xml]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.directoryURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first
            panel.message = "Choose a MUSHclient plugin (.xml) to import."
            panel.prompt = "Analyse"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            pendingImport = PendingImport(sourceURL: url, report: model.report(for: url))
        #endif
    }

    private func install(_ pending: PendingImport) {
        isInstalling = true
        Task {
            let installedID = await model.install(from: pending.sourceURL)
            isInstalling = false
            pendingImport = nil
            if let installedID { model.selection = .imported(installedID) }
        }
    }

    private func removeSelected() async {
        guard let url = model.selectedImportedURL,
              let plugin = model.installed.first(where: { $0.id == url }) else { return }
        await model.remove(plugin)
    }
}

/// A file chosen for import plus its compatibility analysis (`nil` if the
/// file isn't a parseable plugin).
struct PendingImport: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let report: PluginImportReport?
}

// MARK: - Rows

/// One installed plugin in the sidebar: name, author/version, and a marker
/// for files that couldn't be parsed.
private struct PluginRow: View {
    let plugin: InstalledPlugin

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: plugin.parsed ? "puzzlepiece.extension.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(plugin.parsed ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard plugin.parsed else { return "Not a recognised plugin" }
        var parts: [String] = []
        if !plugin.author.isEmpty { parts.append(plugin.author) }
        if !plugin.version.isEmpty { parts.append("v\(plugin.version)") }
        return parts.isEmpty ? plugin.fileName : parts.joined(separator: " · ")
    }
}

/// A built-in native plugin row: name + summary, with an enable toggle.
private struct NativePluginRowView: View {
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

// MARK: - Detail content

/// The detail pane for a built-in native plugin: identity, overview, an
/// enabled badge, and the table of commands it provides.
private struct NativePluginDetail: View {
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

/// The detail pane for an installed plugin: its identity plus the same
/// compatibility report shown during import (so the user can revisit it).
private struct InstalledPluginDetail: View {
    let plugin: InstalledPlugin
    let report: PluginImportReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plugin.name).font(.title2.bold())
                    Text(plugin.fileName).font(.caption).foregroundStyle(.secondary)
                }
                if let report {
                    ReportBody(report: report)
                } else {
                    Label(
                        "This file couldn't be parsed as a MUSHclient plugin.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// The guided-import sheet: shows the report and offers Install / Cancel.
private struct ImportReportSheet: View {
    let pending: PendingImport
    let isInstalling: Bool
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Plugin").font(.title2.bold())
            Text(pending.sourceURL.lastPathComponent)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            Divider()

            if let report = pending.report {
                ScrollView { ReportBody(report: report).padding(.trailing, 4) }
                    .frame(maxHeight: 360)
            } else {
                Label(
                    "This file isn't a recognisable MUSHclient plugin and can't be imported.",
                    systemImage: "xmark.octagon.fill"
                )
                .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: onInstall) {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Install")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending.report == nil || isInstalling)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Verdict badge + plugin counts + the list of findings. Shared by the
/// import sheet and the installed-plugin detail pane.
private struct ReportBody: View {
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
                Text("Nothing notable — uses no scripted world API.")
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

private struct VerdictBadge: View {
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
        case .supported: "Fully supported"
        case .worksWithCaveats: "Works with caveats"
        case .unsupported: "Limited support"
        }
    }

    private var symbol: String {
        switch verdict {
        case .supported: "checkmark.seal.fill"
        case .worksWithCaveats: "exclamationmark.triangle.fill"
        case .unsupported: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch verdict {
        case .supported: .green
        case .worksWithCaveats: .orange
        case .unsupported: .red
        }
    }
}

private struct CountBadge: View {
    let count: Int
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(count)").font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct FindingRow: View {
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
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch finding.severity {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
