import MudCore
import Testing

@Suite("Text view health snapshots")
struct TextViewHealthSnapshotTests {
    @Test("transcript note contains only counts and geometry")
    func transcriptNoteContainsOnlyCountsAndGeometry() {
        let snapshot = TextViewHealthSnapshot(
            surface: "main-output",
            reason: "flush",
            renderedLines: 42,
            storageUTF16Length: 4096,
            textViewBoundsHeight: 500,
            documentHeight: 1200.25,
            visibleOriginY: 700.5,
            visibleHeight: 499.75,
            distanceFromBottom: 0,
            isPinnedToBottom: true,
            isViewHidden: false,
            hasWindow: true,
            extra: "backlog 0 tailLines 10"
        )

        let note = snapshot.transcriptNote(context: "after-stall 123ms")

        #expect(note.contains("text-health: main-output after-stall 123ms"))
        #expect(note.contains("lines 42 storage 4096u16"))
        #expect(note.contains("docH 1200.2"))
        #expect(note.contains("visibleY 700.5"))
        #expect(note.contains("pinned true hidden false window true"))
        #expect(note.contains("source flush"))
        #expect(note.contains("backlog 0 tailLines 10"))
        #expect(!note.contains("first room"))
    }

    @Test("labels are sanitized before transcript output")
    func labelsAreSanitized() {
        let snapshot = TextViewHealthSnapshot(
            surface: "main$output",
            reason: "flush\npayload",
            renderedLines: 0,
            storageUTF16Length: 0,
            textViewBoundsHeight: 0,
            documentHeight: 0,
            visibleOriginY: 0,
            visibleHeight: 0,
            distanceFromBottom: 0,
            isPinnedToBottom: true,
            isViewHidden: false,
            hasWindow: false
        )

        let note = snapshot.transcriptNote()

        #expect(note.contains("text-health: main-output flush-payload"))
    }
}
