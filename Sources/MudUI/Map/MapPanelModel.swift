import MudCore
import Observation
import SwiftUI
#if os(macOS)
    import AppKit
    import UniformTypeIdentifiers
#endif

/// `@Observable` bridge for the graphical GMCP map panel: holds the latest
/// ``MapLayout`` published by the session's ``Mapper`` and turns room clicks
/// into `mapper …` commands (reusing the Stage-4 command surface, so a click
/// routes through exactly the same path as typing the command).
///
/// Binds to whichever ``Mapper`` is currently attached and rebinds when a new
/// world loads, via ``SessionController/mapperAttachments()``.
@MainActor
@Observable
public final class MapPanelModel {
    public private(set) var layout: MapLayout = .build(graph: RoomGraph(), current: "")
    /// Whether neighbouring areas render inline. Mirrors the mapper's setting;
    /// off by default (each area is self-contained), matching Aardwolf.
    public private(set) var showOtherAreas = false
    /// Whether to mark exits leaving the current area. Off by default.
    public private(set) var showAreaExits = false

    /// Result of the most recent import, shown in an alert (nil = none).
    public var importAlert: ImportAlert?

    /// A one-shot import result for the UI alert.
    public struct ImportAlert: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    private let session: SessionController
    private var mapper: Mapper?
    private var bindTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    public init(session: SessionController) {
        self.session = session
    }

    /// Begin mirroring the attached mapper's layout, rebinding on world load.
    /// Idempotent — safe to call from both the app root (so the mapper binds
    /// regardless of which dock tab is shown, e.g. for a menu-triggered import)
    /// and the panel's `onAppear`.
    public func start() {
        guard bindTask == nil else { return }
        bindTask = Task { [weak self] in
            guard let self else { return }
            for await mapper in await session.mapperAttachments() {
                await bind(to: mapper)
            }
        }
    }

    private func bind(to mapper: Mapper) async {
        streamTask?.cancel()
        self.mapper = mapper
        // Adopt the mapper's persisted (per-profile) preferences.
        showOtherAreas = await mapper.showOtherAreas
        showAreaExits = await mapper.showAreaExits
        layout = await mapper.currentLayout()
        let stream = await mapper.subscribeLayout()
        streamTask = Task { [weak self] in
            for await newLayout in stream {
                self?.layout = newLayout
            }
        }
    }

    /// Toggle whether neighbouring areas render inline (pushes to the mapper,
    /// which republishes the layout).
    public func toggleShowOtherAreas() {
        showOtherAreas.toggle()
        let value = showOtherAreas
        Task { await mapper?.setShowOtherAreas(value) }
    }

    /// Toggle the area-exit boundary markers.
    public func toggleShowAreaExits() {
        showAreaExits.toggle()
        let value = showAreaExits
        Task { await mapper?.setShowAreaExits(value) }
    }

    // MARK: - Actions (reuse the `mapper` command surface)

    /// Speedwalk to a room (portals allowed) — the primary click action.
    public func go(to uid: String) {
        send("mapper goto \(uid)")
    }

    /// Walk to a room without portals.
    public func walk(to uid: String) {
        send("mapper walkto \(uid)")
    }

    /// Print a room's name/area/distance to the main output.
    public func showWhere(_ uid: String) {
        send("mapper where \(uid)")
    }

    /// Set (or clear, when empty) a room's note. Calls the mapper directly so
    /// the note text isn't constrained by command parsing; the mapper
    /// republishes the layout so the note marker updates.
    public func setNote(_ text: String, for uid: String) {
        Task { await mapper?.setNote(text, uid: uid) }
    }

    // MARK: - Import

    /// Prompt for a mapper database (default: ~/Documents) and incrementally
    /// merge it — adds rooms/areas/exits/notes we don't already have. The map
    /// refreshes and a summary alert is shown.
    public func importDatabase() {
        #if os(macOS)
            guard let mapper else {
                importAlert = ImportAlert(
                    title: "Connect First",
                    message: "Connect to a world, then import — the map database is per-world."
                )
                return
            }
            let panel = NSOpenPanel()
            panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            panel.allowedContentTypes = [UTType(filenameExtension: "db") ?? .data]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.message = "Choose a mapper database to merge (adds rooms you don't already have)."
            panel.prompt = "Import"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            let accessing = url.startAccessingSecurityScopedResource()
            Task {
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let summary = try await mapper.importMap(from: url)
                    let message = Self.summaryMessage(summary)
                    importAlert = ImportAlert(title: "Map Imported", message: message)
                    // Also echo to the main output so the result is visible even
                    // when the import was triggered from the menu / another tab.
                    await session.echoSystemNote("[Mapper] Import: \(message)")
                } catch {
                    let message = "Couldn't import that file. It may not be a mapper database."
                    importAlert = ImportAlert(title: "Import Failed", message: message)
                    await session.echoSystemNote("[Mapper] Import failed — \(message)")
                }
            }
        #endif
    }

    private static func summaryMessage(_ summary: MapperStore.ImportSummary) -> String {
        guard !summary.isEmpty else {
            return "Nothing new — your map already had everything in that file."
        }
        return """
        Added \(summary.rooms.formatted()) rooms, \(summary.areas.formatted()) areas, \
        \(summary.exits.formatted()) exits, and \(summary.notes.formatted()) notes.
        """
    }

    private func send(_ command: String) {
        Task { try? await session.send(command) }
    }
}
