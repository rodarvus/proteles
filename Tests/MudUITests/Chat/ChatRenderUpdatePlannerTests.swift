import MudCore
@testable import MudUI
import Testing

@Suite("Channels render update planner")
struct ChatRenderUpdatePlannerTests {
    private let presentation = ChatRenderPresentation(
        filterKey: "all",
        showTimestamps: true,
        timestampSeconds: false,
        palette: Theme.default.palette
    )

    @Test("Unchanged displayed ids are a no-op")
    func unchangedIsNoOp() {
        let state = renderState([1, 2, 3])

        #expect(ChatRenderUpdatePlanner.plan(from: state, to: state) == .noChange)
    }

    @Test("A selected filter ignores unrelated source appends")
    func unrelatedAppendIsNoOp() {
        let before = renderState([4, 9], filterKey: "nonchannel:remort_auction")
        let after = renderState([4, 9], filterKey: "nonchannel:remort_auction")

        #expect(ChatRenderUpdatePlanner.plan(from: before, to: after) == .noChange)
    }

    @Test("Tail growth appends only new rows")
    func appendOnly() {
        let update = ChatRenderUpdatePlanner.plan(
            from: renderState([1, 2]),
            to: renderState([1, 2, 3, 4])
        )

        #expect(update == .incremental(removeFirst: 0, appendFrom: 2))
    }

    @Test("Rolling capacity trims the prefix and appends the tail")
    func rollingTrimAndAppend() {
        let update = ChatRenderUpdatePlanner.plan(
            from: renderState([10, 11, 12, 13]),
            to: renderState([12, 13, 14, 15])
        )

        #expect(update == .incremental(removeFirst: 2, appendFrom: 2))
    }

    @Test("A filter change rebuilds even when ids match")
    func filterChangeRebuilds() {
        let update = ChatRenderUpdatePlanner.plan(
            from: renderState([1, 2], filterKey: "all"),
            to: renderState([1, 2], filterKey: "channel:gossip")
        )

        #expect(update == .rebuild)
    }

    @Test("Timestamp or palette changes rebuild")
    func presentationChangeRebuilds() {
        let before = renderState([1, 2])
        let changed = ChatRenderState(
            lineIDs: before.lineIDs,
            presentation: ChatRenderPresentation(
                filterKey: "all",
                showTimestamps: false,
                timestampSeconds: false,
                palette: Theme.default.palette
            )
        )

        #expect(ChatRenderUpdatePlanner.plan(from: before, to: changed) == .rebuild)
    }

    @Test("Non-overlapping replacement rebuilds")
    func replacementRebuilds() {
        let update = ChatRenderUpdatePlanner.plan(
            from: renderState([1, 2, 3]),
            to: renderState([7, 8, 9])
        )

        #expect(update == .rebuild)
    }

    private func renderState(_ ids: [UInt64], filterKey: String = "all") -> ChatRenderState {
        ChatRenderState(
            lineIDs: ids,
            presentation: ChatRenderPresentation(
                filterKey: filterKey,
                showTimestamps: presentation.showTimestamps,
                timestampSeconds: presentation.timestampSeconds,
                palette: presentation.palette
            )
        )
    }
}
