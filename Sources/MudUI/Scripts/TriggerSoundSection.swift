import MudCore
import SwiftUI
import UniformTypeIdentifiers

/// The trigger editor's Sound section (S1 step 4, #83): none, a vocabulary
/// event, or a file from the Sounds folder. The trigger stores a file's
/// *name*, not a path, so it travels with the profile; "Add File…" copies a
/// chosen file into the folder first.
struct TriggerSoundSection: View {
    @Binding var sound: TriggerSound?
    @State private var files: [String] = []
    @State private var importing = false
    @State private var importError: String?

    private enum Kind: Hashable {
        case none, event, file
    }

    var body: some View {
        Section("Sound") {
            Picker("Play", selection: kind) {
                Text("Nothing").tag(Kind.none)
                Text("A soundpack event").tag(Kind.event)
                Text("A sound file").tag(Kind.file)
            }
            switch sound {
            case .event:
                Picker("Event", selection: eventName) {
                    ForEach(Self.eventGroups, id: \.category) { group in
                        Section(group.category.rawValue.capitalized) {
                            ForEach(group.names, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            case .file(let name):
                Picker("File", selection: fileName) {
                    if name.isEmpty { Text("Choose a file").tag("") }
                    if !name.isEmpty, !files.contains(name) {
                        Text("\(name) (not in the Sounds folder)").tag(name)
                    }
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }
                Button("Add File…") { importing = true }
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.red)
                }
            case nil:
                EmptyView()
            }
            if sound != nil {
                Text("Plays through the soundpack. `spmute` turns sound on and off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { files = Self.soundFiles() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            addFile(result)
        }
    }

    // MARK: - Bindings

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch sound {
                case .event: .event
                case .file: .file
                case nil: .none
                }
            },
            set: { newKind in
                switch newKind {
                case .none: sound = nil
                case .event: sound = .event(name: "tell")
                case .file: sound = .file(name: files.first ?? "")
                }
            }
        )
    }

    private var eventName: Binding<String> {
        Binding(
            get: { if case .event(let name) = sound { name } else { "" } },
            set: { sound = .event(name: $0) }
        )
    }

    private var fileName: Binding<String> {
        Binding(
            get: { if case .file(let name) = sound { name } else { "" } },
            set: { sound = .file(name: $0) }
        )
    }

    // MARK: - Data

    /// The vocabulary a trigger can name, by category — every event except
    /// `trigger_sound` itself, which is what a file sound plays as.
    private static let eventGroups: [(category: SemanticEvent.Category, names: [String])] =
        SemanticEvent.Category.allCases.compactMap { category in
            let names = SemanticEventVocabulary.categories
                .filter { $0.value == category && $0.key != TriggerSound.triggerSoundEvent }
                .map(\.key)
                .sorted()
            return names.isEmpty ? nil : (category, names)
        }

    private static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf"]

    /// The audio files directly in the Sounds folder, by name.
    private static func soundFiles() -> [String] {
        guard let directory = try? ProtelesPaths.soundsDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        return names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Copy a chosen file into the Sounds folder (replacing one of the same
    /// name) and select it.
    private func addFile(_ result: Result<URL, Error>) {
        importError = nil
        do {
            let source = try result.get()
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let destination = try ProtelesPaths.soundsDirectory()
                .appendingPathComponent(source.lastPathComponent)
            if destination.standardizedFileURL != source.standardizedFileURL {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            files = Self.soundFiles()
            sound = .file(name: source.lastPathComponent)
        } catch {
            importError = "Couldn't add the file: \(error.localizedDescription)"
        }
    }
}
