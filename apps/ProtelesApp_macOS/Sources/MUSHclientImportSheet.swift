import MudCore
import SwiftUI

/// The MUSHclient import review sheet: shows what the scan found and lets the
/// user choose what to bring over, then runs the import. Driven by
/// ``MUSHclientImportModel``.
struct MUSHclientImportSheet: View {
    @Bindable var model: MUSHclientImportModel
    @Environment(\.dismiss) private var dismiss

    @State private var importScriptsKeypad = true
    @State private var selectedPlugins: Set<String> = []
    @State private var selectedDatabases: Set<String> = []
    @State private var character = ""
    @State private var profileName = "Aardwolf (imported)"

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle, .scanning: progress("Scanning MUSHclient install…")
            case .review: review
            case .importing: progress("Importing…")
            case .done: done
            case .failed(let message): failure(message)
            }
        }
        .frame(width: 560, height: 560)
        .onChange(of: model.phase) { _, _ in seedSelection() }
    }

    private func progress(_ label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    @ViewBuilder private var review: some View {
        if let scan = model.scan {
            Form {
                Section("Connection") {
                    LabeledContent("World", value: scan.world.name)
                    LabeledContent("Host", value: "\(scan.world.host):\(scan.world.port)")
                    if !scan.world.username.isEmpty {
                        LabeledContent("Character", value: scan.world.username)
                    }
                    TextField("Import as profile", text: $profileName)
                }
                Section("Scripts") {
                    Toggle(scriptsLabel(scan.world), isOn: $importScriptsKeypad)
                    TextField("Target character", text: $character)
                }
                pluginsSection(scan)
                databasesSection(scan)
                if !scan.manifest.problems.isEmpty {
                    Section("Issues (\(scan.manifest.problems.count))") {
                        ForEach(scan.manifest.problems, id: \.item) { problem in
                            Label(
                                "\(problem.item): \(problem.reason)",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            footer(importTitle: "Import")
        }
    }

    @ViewBuilder private func pluginsSection(_ scan: MUSHclientImportScan.Scan) -> some View {
        let offers = scan.manifest.plugins.filter { $0.classification == .offer }
        let skipped = scan.manifest.plugins.count - offers.count
        Section("Plugins — \(offers.count) to import, \(skipped) already provided") {
            ForEach(offers) { plugin in
                Toggle(isOn: membership($selectedPlugins, plugin.include)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(plugin.name ?? plugin.filename)
                        let sidecars = plugin.dataFiles.count + plugin.pluginDirSidecars.count
                        if sidecars > 0 {
                            Text("includes \(sidecars) data file" + (sidecars == 1 ? "" : "s"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func databasesSection(_ scan: MUSHclientImportScan.Scan) -> some View {
        let importable = scan.manifest.databases.filter { $0.kind != .unknown }
        if !importable.isEmpty {
            Section("Databases") {
                ForEach(importable) { database in
                    Toggle(databaseLabel(database), isOn: membership($selectedDatabases, database.id))
                }
            }
        }
    }

    /// A `Bool` binding for whether `key` is in the selection set.
    private func membership(_ set: Binding<Set<String>>, _ key: String) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(key) },
            set: {
                set.wrappedValue = $0 ? set.wrappedValue.union([key]) : set.wrappedValue.subtracting([key])
            }
        )
    }

    private func scriptsLabel(_ world: MUSHclientWorldFile) -> String {
        var parts: [String] = []
        if !world.aliases.isEmpty { parts.append("\(world.aliases.count) aliases") }
        if !world.triggers.isEmpty { parts.append("\(world.triggers.count) triggers") }
        if !world.macros.isEmpty { parts.append("\(world.macros.count) macros") }
        if !world.keypad.isEmpty { parts.append("keypad (\(world.keypad.count))") }
        return parts.isEmpty ? "Aliases, triggers, macros, keypad" : parts.joined(separator: ", ")
    }

    private func databaseLabel(_ database: ImportManifest.DatabaseEntry) -> String {
        let file = database.url.lastPathComponent
        switch database.kind {
        case .mapper: return "Mapper (\(file))"
        case .searchAndDestroy: return "Search & Destroy (\(file))"
        case .dinv: return "Inventory — \(database.character ?? "?") (\(file))"
        case .leveldb: return "Leveling (\(file))"
        case .pluginOwned, .unknown: return file // show the filename, not the raw kind
        }
    }

    // MARK: - Done / failure

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("Import complete").font(.headline)
            if let result = model.result, !result.problems.isEmpty {
                Text("\(result.problems.count) item(s) couldn't be imported.")
                    .foregroundStyle(.secondary)
                Button("Report problems on GitHub") { openReport() }
            }
            if let backup = model.backupURL {
                Button("Reveal backup") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup])
                }
                .font(.caption)
            }
            Text("Restart Proteles to use the imported profile.").font(.caption).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.red)
            Text("Import failed").font(.headline)
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(importTitle: String) -> some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(importTitle) { runImport() }.keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    // MARK: - Actions

    private func seedSelection() {
        guard case .review = model.phase, let scan = model.scan else { return }
        selectedPlugins = Set(scan.manifest.plugins.filter { $0.classification == .offer }.map(\.include))
        selectedDatabases = Set(scan.manifest.databases.filter { $0.kind != .unknown }.map(\.id))
        if character.isEmpty { character = scan.world.username.isEmpty ? "Default" : scan.world.username }
    }

    private func runImport() {
        let target: ProfileImporter.Target = .newProfile(name: profileName)
        model.runImport(selection: .init(
            importScriptsAndKeypad: importScriptsKeypad,
            pluginIncludes: selectedPlugins,
            databasePaths: selectedDatabases,
            target: target,
            character: character.isEmpty ? "Default" : character
        ))
    }

    private func openReport() {
        let body = "MUSHclient import reported problems:\n\n"
            + (model.result?.problems.map { "- \($0.item): \($0.reason)" }.joined(separator: "\n") ?? "")
        var components = URLComponents(string: "https://github.com/rodarvus/proteles/issues/new")
        components?.queryItems = [
            .init(name: "title", value: "MUSHclient import problem"),
            .init(name: "body", value: body)
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }
}
