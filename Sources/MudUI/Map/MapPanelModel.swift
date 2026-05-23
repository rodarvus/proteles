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

    private let session: SessionController
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
        layout = await mapper.currentLayout()
        let stream = await mapper.subscribeLayout()
        streamTask = Task { [weak self] in
            for await newLayout in stream {
                self?.layout = newLayout
            }
        }
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

    private func send(_ command: String) {
        Task { try? await session.send(command) }
    }
}
