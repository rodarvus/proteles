import MudCore
import Observation
import SwiftUI

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

    private let session: SessionController
    private var mapper: Mapper?
    private var bindTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?

    public init(session: SessionController) {
        self.session = session
    }

    /// Begin mirroring the attached mapper's layout, rebinding on world load.
    public func start() {
        bindTask?.cancel()
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
        await mapper.setShowOtherAreas(showOtherAreas)
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

    private func send(_ command: String) {
        Task { try? await session.send(command) }
    }
}
