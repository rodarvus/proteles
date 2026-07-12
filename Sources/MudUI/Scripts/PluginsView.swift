import MudCore
import SwiftUI
#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers
#endif

/// The Plugins window's three panes (D-107): a category sidebar (Core
/// Features / Modules / Library), the selected category's items —
/// alphabetised, with enable toggles — and the detail pane.
enum PluginCategory: String, CaseIterable, Identifiable, Hashable {
    case features, modules, library

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .features: "Core Features"
        case .modules: "Modules"
        case .library: "Library"
        }
    }

    var icon: String {
        switch self {
        case .features: "map"
        case .modules: "gearshape.2"
        case .library: "puzzlepiece.extension"
        }
    }
}

/// An error surfaced to the user: a plain-language headline + the technical
/// detail underneath (never a bare `localizedDescription`, DESIGN.md §3.7).
struct PluginsError: Identifiable {
    let id = UUID()
    let title: String
    let advice: String
    let detail: String
}

/// The "Plugins" window: the user's plugin library plus the built-in
/// features/modules, three-paned (D-107). Adding shows a compatibility
/// report (``PluginImporter``) before anything goes in; every added plugin
/// lives in its own discoverable directory under
/// `~/Documents/Proteles/Plugins/<name>/`. Changes apply to the live
/// session immediately.
public struct PluginsView: View {
    @Bindable private var model: PluginsModel

    @State private var category: PluginCategory? = .library
    /// A plugin staged for adding (files chosen / download extracted), paired
    /// with its analysis. Drives the report sheet. `nil` when none in progress.
    @State private var pendingAdd: PendingAdd?
    /// Remaining plugin groups when several distinct plugins were selected at
    /// once — each is staged through the confirm sheet in turn (see
    /// ``advanceQueue()``). Empty for the common single-plugin add.
    @State private var pendingQueue: [[URL]] = []
    @State private var isAdding = false
    @State private var urlPromptShown = false
    @State private var urlText = ""
    @State private var presentedError: PluginsError?
    /// A library plugin staged for removal, awaiting confirmation (§3.7).
    @State private var removalCandidate: LibraryPluginRow?

    public init(model: PluginsModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            categorySidebar
        } content: {
            categoryContent
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 440)
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
        .alert(item: $presentedError) { error in
            Alert(
                title: Text(error.title),
                message: Text("\(error.advice)\n\n\(error.detail)"),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("Couldn’t Change Module", isPresented: moduleErrorPresented) {
            Button("OK") { model.moduleError = nil }
        } message: {
            Text("The setting could not be saved, so the live module was left unchanged.\n\n"
                + (model.moduleError ?? "Unknown error"))
        }
        .confirmationDialog(
            removalCandidate.map { "Remove the plugin “\($0.name)”?" } ?? "",
            isPresented: confirmingRemoval,
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { plugin in
            Button("Remove Plugin", role: .destructive) {
                Task { await model.remove(pluginID: plugin.id) }
            }
        } message: { _ in
            Text("This unloads it and deletes its folder — including any data "
                + "it saved — from your Plugins library. You can't undo this.")
        }
    }

    // MARK: - Columns

    private var categorySidebar: some View {
        List(selection: $category) {
            ForEach(PluginCategory.allCases) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category)
            }
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        .onChange(of: category) { _, _ in model.selection = nil }
    }

    private var categoryContent: some View {
        Group {
            switch category ?? .library {
            case .features: featuresList
            case .modules: modulesList
            case .library: libraryList
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("From your Mac…", action: beginAddFromMac)
                        .keyboardShortcut("n", modifiers: .command)
                    Button("From a URL…") { urlText = ""; urlPromptShown = true }
                } label: {
                    Label("Add Plugin…", systemImage: "plus")
                }
                .help("Add a MUSHclient plugin to the library (⌘N for a file)")
                Button {
                    if let plugin = model.selectedLibrary { removalCandidate = plugin }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove the selected library plugin (⌫ in the list)")
                .disabled(model.selectedLibrary == nil)
            }
        }
    }

    private var featuresList: some View {
        List(selection: $model.selection) {
            ForEach(model.sortedFeatures) { feature in
                BuiltInFeatureRowView(
                    feature: feature,
                    enabled: model.featureEnabled(feature.id),
                    onToggle: { enabled in
                        Task { await model.setFeatureEnabled(enabled, id: feature.id) }
                    }
                )
                .tag(PluginSelection.feature(feature.id))
            }
        }
    }

    private var modulesList: some View {
        List(selection: $model.selection) {
            ForEach(model.sortedNatives) { plugin in
                NativePluginRowView(plugin: plugin) { enabled in
                    Task { await model.setNativeEnabled(enabled, id: plugin.id) }
                }
                .tag(PluginSelection.native(plugin.id))
            }
        }
    }

    @ViewBuilder
    private var libraryList: some View {
        if model.libraryPlugins.isEmpty {
            ContentUnavailableView {
                Label("No Plugins", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Add a MUSHclient plugin — from your Mac or a URL — "
                    + "to get started.")
            } actions: {
                Button("Add from your Mac…", action: beginAddFromMac)
            }
        } else {
            List(selection: $model.selection) {
                ForEach(model.sortedLibrary) { plugin in
                    LibraryPluginRowView(plugin: plugin) { enabled in
                        Task { await model.setEnabled(enabled, pluginID: plugin.id) }
                    }
                    .tag(PluginSelection.library(plugin.id))
                }
            }
            .onDeleteCommandCompat {
                if let plugin = model.selectedLibrary { removalCandidate = plugin }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let feature = model.selectedFeature {
            BuiltInFeatureDetail(
                feature: feature,
                enabled: model.featureEnabled(feature.id),
                onToggle: { enabled in
                    Task { await model.setFeatureEnabled(enabled, id: feature.id) }
                }
            )
        } else if let native = model.selectedNative {
            NativePluginDetail(plugin: native)
        } else if let plugin = model.selectedLibrary {
            LibraryPluginDetail(
                plugin: plugin,
                report: report(for: plugin),
                onReveal: { reveal(plugin) },
                onUpdate: { update(plugin) },
                onExport: { export(plugin) },
                onRemove: { removalCandidate = plugin }
            )
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "puzzlepiece.extension",
                description: Text("Select an item to see what it does, or add a plugin.")
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

    private var confirmingRemoval: Binding<Bool> {
        Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )
    }

    private var moduleErrorPresented: Binding<Bool> {
        Binding(
            get: { model.moduleError != nil },
            set: { if !$0 { model.moduleError = nil } }
        )
    }

    private func beginAddFromMac() {
        #if os(macOS)
            guard let sources = chooseFiles(
                message: "Choose one or more plugins — each plugin's .xml, the folder "
                    + "that contains it, or all of its files.",
                prompt: "Add"
            ), !sources.isEmpty else { return }
            // A selection can be several *distinct* plugins (install each) or one
            // plugin's loose files. Stage the first; the rest queue behind it.
            let groups = pluginGroups(from: sources)
            guard let first = groups.first else { return }
            pendingQueue = Array(groups.dropFirst())
            stageFileGroup(first)
        #endif
    }

    #if os(macOS)
        /// Split a multi-selection into distinct plugins. Each chosen *folder* is
        /// its own plugin; among loose files, two-or-more `.xml` files mean the
        /// user picked several separate plugins (install each), while a single
        /// `.xml` plus any loose sidecar files is one plugin — preserving the
        /// "all of its files" case. (A mix of several `.xml`s with loose `.lua`
        /// sidecars is inherently ambiguous, so loose non-xml files are dropped
        /// in that case; import such a plugin on its own or as a folder.)
        private func pluginGroups(from sources: [URL]) -> [[URL]] {
            let fileManager = FileManager.default
            func isDirectory(_ url: URL) -> Bool {
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            let directories = sources.filter(isDirectory)
            let files = sources.filter { !isDirectory($0) }
            let xmls = files.filter { $0.pathExtension.lowercased() == "xml" }
            var groups: [[URL]] = directories.map { [$0] }
            if xmls.count >= 2 {
                groups += xmls.map { [$0] }
            } else if !files.isEmpty {
                groups.append(files)
            }
            return groups
        }

        /// Stage one plugin group (a folder, or an `.xml` + its sidecars) into the
        /// confirm sheet, naming it after its `.xml` (or folder).
        private func stageFileGroup(_ group: [URL]) {
            let name = group.first { $0.pathExtension.lowercased() == "xml" }?.lastPathComponent
                ?? group.first?.lastPathComponent ?? "Plugin"
            stage(sources: group, displayName: name, origin: nil, tempDir: nil)
        }

        /// Stage the next queued plugin into the sheet; `false` if none remain.
        @discardableResult
        private func advanceQueue() -> Bool {
            guard !pendingQueue.isEmpty else { return false }
            stageFileGroup(pendingQueue.removeFirst())
            return true
        }
    #endif

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
                presentedError = PluginsError(
                    title: "Couldn't download the plugin",
                    advice: "Check the URL points at a plugin .xml, or a .zip "
                        + "release/repo download, and that you're online.",
                    detail: error.localizedDescription
                )
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
            // Advancing reassigns `pendingAdd` to the next queued plugin (the
            // sheet stays up, content swaps); only clear it when the queue's dry.
            #if os(macOS)
                if advanceQueue() { return }
            #endif
            pendingAdd = nil
        }
    }

    private func cancelAdd(_ pending: PendingAdd) {
        if let temp = pending.tempDir { try? FileManager.default.removeItem(at: temp) }
        pendingQueue.removeAll() // cancelling aborts the rest of a batch
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
                presentedError = PluginsError(
                    title: "Couldn't export the plugin",
                    advice: "Check you can write to the chosen location.",
                    detail: error.localizedDescription
                )
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
