import MudCore
import SwiftUI
#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers
#endif

/// The "Plugins" window: lists the user's added plugins (the library) plus the
/// built-in native features, and adds new ones — from your Mac or a URL —
/// showing a compatibility report (what works, what doesn't) from
/// ``PluginImporter`` before they go in. Every added plugin lives in its own
/// discoverable directory under `~/Documents/Proteles/Plugins/<name>/`
/// (see `docs/plans/PLUGIN_LIBRARY_PLAN.md`). Adding / removing / toggling /
/// updating re-syncs the live session so the change applies immediately.
public struct PluginsView: View {
    @Bindable private var model: PluginsModel

    /// A plugin staged for adding (files chosen / download extracted), paired
    /// with its analysis. Drives the report sheet. `nil` when none in progress.
    @State private var pendingAdd: PendingAdd?
    @State private var isAdding = false
    @State private var urlPromptShown = false
    @State private var urlText = ""
    @State private var errorMessage: String?

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
        .sheet(item: $pendingAdd) { pending in
            AddPluginReportSheet(
                pending: pending,
                isAdding: isAdding,
                onAdd: { finishAdd(pending) },
                onCancel: { cancelAdd(pending) }
            )
        }
        .sheet(isPresented: $urlPromptShown) { urlPromptSheet }
        .alert("Couldn't add the plugin", isPresented: errorBinding) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Core features") {
                ForEach(model.builtInFeatures) { feature in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.name).font(.body)
                        Text("Built in · always active")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(PluginSelection.feature(feature.id))
                }
            }
            if !model.nativePlugins.isEmpty {
                Section("Native plugins") {
                    ForEach(model.nativePlugins) { plugin in
                        NativePluginRowView(plugin: plugin) { enabled in
                            Task { await model.setNativeEnabled(enabled, id: plugin.id) }
                        }
                        .tag(PluginSelection.native(plugin.id))
                    }
                }
            }
            Section("Plugins") {
                ForEach(model.libraryPlugins) { plugin in
                    LibraryPluginRowView(plugin: plugin) { enabled in
                        Task { await model.setEnabled(enabled, pluginID: plugin.id) }
                    }
                    .tag(PluginSelection.library(plugin.id))
                }
                if model.libraryPlugins.isEmpty {
                    Text("Add a MUSHclient plugin — from your Mac or a URL — to get started.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("From your Mac…", action: beginAddFromMac)
                    Button("From a URL…") { urlText = ""; urlPromptShown = true }
                } label: {
                    Label("Add Plugin…", systemImage: "plus")
                }
                Button {
                    if let id = model.selectedLibrary?.id { Task { await model.remove(pluginID: id) } }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .disabled(model.selectedLibrary == nil)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let feature = model.selectedFeature {
            BuiltInFeatureDetail(feature: feature)
        } else if let native = model.selectedNative {
            NativePluginDetail(plugin: native)
        } else if let plugin = model.selectedLibrary {
            LibraryPluginDetail(
                plugin: plugin,
                report: report(for: plugin),
                onReveal: { reveal(plugin) },
                onUpdate: { update(plugin) },
                onExport: { export(plugin) },
                onRemove: { Task { await model.remove(pluginID: plugin.id) } }
            )
        } else {
            ContentUnavailableView(
                "No Plugin Selected",
                systemImage: "puzzlepiece.extension",
                description: Text("Select a plugin to see what it does, or add a new one.")
            )
        }
    }

    private func report(for plugin: LibraryPluginRow) -> PluginImportReport? {
        model.report(forSources: [plugin.directory]).report
    }

    // MARK: - URL prompt sheet

    private var urlPromptSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Plugin from a URL").font(.title2.bold())
            Text("Paste a link to a plugin — a raw .xml file, or a .zip (a release "
                + "asset or a GitHub repo/branch download). It'll be downloaded into "
                + "your Plugins folder.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://…", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitURL)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { urlPromptShown = false }
                    .keyboardShortcut(.cancelAction)
                Button("Download", action: submitURL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(URL(string: urlText.trimmingCharacters(in: .whitespaces)) == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Actions

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func beginAddFromMac() {
        #if os(macOS)
            guard let sources = chooseFiles(
                message: "Choose a plugin — its .xml, the folder that contains it, "
                    + "or all of its files.",
                prompt: "Add"
            ), !sources.isEmpty else { return }
            stage(
                sources: sources,
                displayName: sources.first?.lastPathComponent ?? "Plugin",
                origin: nil,
                tempDir: nil
            )
        #endif
    }

    private func submitURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else { return }
        urlPromptShown = false
        Task {
            do {
                let temp = try await model.stageDownload(from: url)
                stage(
                    sources: [temp],
                    displayName: url.lastPathComponent,
                    origin: .url(url.absoluteString),
                    tempDir: temp
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Build the report for staged sources and show the confirm sheet.
    private func stage(sources: [URL], displayName: String, origin: PluginOrigin?, tempDir: URL?) {
        let (_, report) = model.report(forSources: sources)
        pendingAdd = PendingAdd(
            sources: sources, displayName: displayName, report: report, origin: origin, tempDir: tempDir
        )
    }

    private func finishAdd(_ pending: PendingAdd) {
        isAdding = true
        Task {
            await model.add(sources: pending.sources, origin: pending.origin)
            isAdding = false
            if let temp = pending.tempDir { try? FileManager.default.removeItem(at: temp) }
            pendingAdd = nil
        }
    }

    private func cancelAdd(_ pending: PendingAdd) {
        if let temp = pending.tempDir { try? FileManager.default.removeItem(at: temp) }
        pendingAdd = nil
    }

    private func reveal(_ plugin: LibraryPluginRow) {
        #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
        #endif
    }

    private func export(_ plugin: LibraryPluginRow) {
        #if os(macOS)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.nameFieldStringValue = "\(plugin.directory.lastPathComponent).zip"
            panel.message = "Export this plugin as a zip to share (its per-character data is excluded)."
            panel.prompt = "Export"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            do {
                try PluginExporter.export(pluginDirectory: plugin.directory, to: destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        #endif
    }

    private func update(_ plugin: LibraryPluginRow) {
        switch plugin.origin {
        case .url:
            Task { await model.refreshFromURL(pluginID: plugin.id) }
        case .file:
            #if os(macOS)
                guard let sources = chooseFiles(
                    message: "Choose the updated plugin — its .xml, the folder, or all of its files.",
                    prompt: "Update"
                ), !sources.isEmpty else { return }
                Task { await model.updateFromFiles(pluginID: plugin.id, sources: sources) }
            #endif
        }
    }

    #if os(macOS)
        /// Run an open panel (files + folders, multi-select), starting in
        /// Documents. Returns the chosen URLs, or `nil` if cancelled.
        private func chooseFiles(message: String, prompt: String) -> [URL]? {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.directoryURL = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first
            panel.message = message
            panel.prompt = prompt
            return panel.runModal() == .OK ? panel.urls : nil
        }
    #endif
}

/// A plugin staged for adding plus its compatibility analysis (`nil` report if
/// the files aren't a parseable plugin). `tempDir` is removed after add/cancel.
struct PendingAdd: Identifiable {
    let id = UUID()
    let sources: [URL]
    let displayName: String
    let report: PluginImportReport?
    let origin: PluginOrigin?
    let tempDir: URL?
}
