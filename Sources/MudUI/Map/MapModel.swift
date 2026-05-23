import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge over ``MapStore`` for the Map window: holds the most
/// recent captured ASCII map's styled lines. Same bridging pattern as
/// ``ChatModel`` over ``ChatStore``.
@MainActor
@Observable
public final class MapModel {
    public private(set) var lines: [Line] = []

    private let store: MapStore
    private var streamTask: Task<Void, Never>?

    public init(store: MapStore) {
        self.store = store
    }

    /// Begin mirroring the store: read the current map, then stream updates.
    public func start() async {
        let stream = await store.subscribe()
        lines = await store.map
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            for await map in stream {
                self?.lines = map
            }
        }
    }
}
