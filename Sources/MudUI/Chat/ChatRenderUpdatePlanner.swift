import MudCore

/// Presentation inputs that change the attributed representation of Channels
/// lines. Geometry changes are deliberately absent: TextKit reflows the same
/// storage when its container width changes.
struct ChatRenderPresentation: Equatable {
    let filterKey: String
    let showTimestamps: Bool
    let timestampSeconds: Bool
    let palette: ColorPalette
}

/// The identity of the document currently installed in the Channels text
/// storage. Chat lines are immutable and their ids are unique for the lifetime
/// of a store, so ids plus presentation completely describe rendered content.
struct ChatRenderState: Equatable {
    let lineIDs: [UInt64]
    let presentation: ChatRenderPresentation
}

/// Minimal mutation needed to move an existing Channels document to the next
/// state. A rolling bounded buffer is represented as one prefix trim plus one
/// tail append, matching the reference client's add/prune behavior.
enum ChatRenderUpdate: Equatable {
    case noChange
    case rebuild
    case incremental(removeFirst: Int, appendFrom: Int)
}

enum ChatRenderUpdatePlanner {
    static func state(
        lines: [ChatLine],
        presentation: ChatRenderPresentation
    ) -> ChatRenderState {
        ChatRenderState(lineIDs: lines.map(\.id), presentation: presentation)
    }

    static func plan(
        from previous: ChatRenderState?,
        to next: ChatRenderState
    ) -> ChatRenderUpdate {
        guard let previous, previous.presentation == next.presentation else {
            return .rebuild
        }
        let old = previous.lineIDs
        let new = next.lineIDs
        if old == new { return .noChange }

        if old.isEmpty {
            return .incremental(removeFirst: 0, appendFrom: 0)
        }
        if new.isEmpty { return .rebuild }

        if new.count >= old.count, new.prefix(old.count).elementsEqual(old) {
            return .incremental(removeFirst: 0, appendFrom: old.count)
        }

        guard let firstSurvivor = old.firstIndex(of: new[0]) else { return .rebuild }
        let overlapCount = min(old.count - firstSurvivor, new.count)
        guard old[firstSurvivor...].prefix(overlapCount)
            .elementsEqual(new.prefix(overlapCount)),
            firstSurvivor + overlapCount == old.count
        else { return .rebuild }

        return .incremental(removeFirst: firstSurvivor, appendFrom: overlapCount)
    }
}
