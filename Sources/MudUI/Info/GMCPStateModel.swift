import MudCore
import Observation
import SwiftUI

/// `@Observable` reference holder for the live ``GMCPState`` snapshot (#61).
///
/// GMCP-driven views (the gauge bar, the Character/Group panels) read
/// `model.state` inside their **own** bodies, so Observation registers the
/// dependency at the leaf — only those views re-render per update. The root
/// view holds the reference without ever reading `state` in its body.
///
/// Why this exists: the snapshot used to live in a root-level
/// `@State var gmcp = GMCPState()` (a value), reassigned on **every** GMCP
/// change — `char.vitals` per combat action, `room.info` per room (~10/s on
/// a continent run). Each write invalidated the window root, and the
/// resulting whole-window AttributeGraph diffs were the dominant cause of
/// the multi-second main-thread stalls measured live on 2026-06-11.
@MainActor
@Observable
public final class GMCPStateModel {
    public var state: GMCPState

    public init(state: GMCPState = GMCPState()) {
        self.state = state
    }
}
