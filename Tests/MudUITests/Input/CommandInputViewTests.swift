@testable import MudUI
import Testing

#if os(macOS)
    import AppKit
    import MudCore
    import SwiftUI
#endif

@Suite("CommandInputView smoke")
struct CommandInputViewSmokeTests {
    @MainActor
    @Test("CommandInputView constructs with a submission closure")
    func constructsWithSubmissionClosure() {
        // Phase 1 smoke: SwiftUI views are exercised through previews and
        // app-level integration. This test catches build-time regressions
        // — the view must compile and accept a closure of the documented
        // shape.
        _ = CommandInputView { _ in }
    }

    #if os(macOS)
        @MainActor
        @Test("macOS input hosts a dedicated NSTextView")
        func macOSInputHostsTextView() throws {
            let hosted = try HostedCommandInput()

            #expect(hosted.textView.identifier?.rawValue == "proteles.command")
            #expect(hosted.textView.accessibilityIdentifier() == "command-input")
            #expect(hosted.textView.isHorizontallyResizable == false)
            #expect(hosted.textView.textContainer?.widthTracksTextView == true)
            #expect(hosted.textView.textContainer?.lineFragmentPadding == 0)
            #expect(hosted.textView.enclosingScrollView?.hasHorizontalScroller == false)
        }

        @MainActor
        @Test("Enter submits and clears the command text view")
        func enterSubmitsAndClears() throws {
            let submitted = SubmissionRecorder()
            let hosted = try HostedCommandInput(onSubmit: submitted.append)

            hosted.setText("look")
            hosted.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            #expect(submitted.values == ["look"])
            #expect(hosted.textView.string.isEmpty)
        }

        @MainActor
        @Test("multi-line submit preserves blank lines")
        func multilineSubmitPreservesBlankLines() throws {
            let submitted = SubmissionRecorder()
            let hosted = try HostedCommandInput(onSubmit: submitted.append)

            hosted.setText("north\n\nlook\n")
            hosted.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            #expect(submitted.values == ["north", "", "look", ""])
            #expect(hosted.textView.string.isEmpty)
        }

        @MainActor
        @Test("multi-line submit uses a single batch callback")
        func multilineSubmitUsesBatchCallback() throws {
            let submitted = SubmissionRecorder()
            var batches: [[String]] = []
            let hosted = try HostedCommandInput(
                onSubmit: submitted.append,
                onSubmitBatch: { batches.append($0) }
            )

            hosted.setText("first\nsecond\nthird")
            hosted.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            #expect(submitted.values.isEmpty)
            #expect(batches == [["first", "second", "third"]])
            #expect(hosted.textView.string.isEmpty)
        }

        @MainActor
        @Test("insertNewlineIgnoringFieldEditor inserts a literal newline")
        func ignoringFieldEditorInsertsNewline() throws {
            let submitted = SubmissionRecorder()
            let hosted = try HostedCommandInput(onSubmit: submitted.append)

            hosted.setText("say hello")
            hosted.textView.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))

            #expect(submitted.values.isEmpty)
            #expect(hosted.textView.string == "say hello\n")
        }

        @MainActor
        @Test("Tab completion cycles through the completion vocabulary")
        func tabCompletionCycles() throws {
            let hosted = try HostedCommandInput(
                vocabulary: {
                    CompletionVocabulary(contextWords: ["north", "northeast"])
                }
            )

            hosted.setText("no")
            hosted.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(hosted.textView.string == "north")

            hosted.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(hosted.textView.string == "northeast")
        }

        @MainActor
        @Test("Up arrow navigates inside multi-line input before history recall")
        func upArrowNavigatesMultilineBeforeHistory() throws {
            let submitted = SubmissionRecorder()
            let hosted = try HostedCommandInput(onSubmit: submitted.append)

            hosted.setText("look")
            hosted.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            hosted.setText("north\nsouth")
            hosted.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))

            #expect(hosted.textView.string == "north\nsouth")

            hosted.textView.setSelectedRange(NSRange(location: 0, length: 0))
            hosted.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))

            #expect(hosted.textView.string == "look")
        }

        @MainActor
        @Test("text editing policy disables command-mangling substitutions")
        func textEditingPolicy() {
            let textView = AutoFocusCommandTextView(frame: .zero)
            textView.spellChecking = false

            textView.applyTextEditingPolicy()

            #expect(textView.isAutomaticQuoteSubstitutionEnabled == false)
            #expect(textView.isAutomaticDashSubstitutionEnabled == false)
            #expect(textView.isAutomaticTextReplacementEnabled == false)
            #expect(textView.isAutomaticSpellingCorrectionEnabled == false)
            #expect(textView.isGrammarCheckingEnabled == false)
            #expect(textView.isContinuousSpellCheckingEnabled == false)
        }
    #endif
}

#if os(macOS)
    @MainActor
    private final class SubmissionRecorder {
        private(set) var values: [String] = []

        func append(_ value: String) {
            values.append(value)
        }
    }

    @MainActor
    private final class HostedCommandInput {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let textView: AutoFocusCommandTextView

        init(
            onSubmit: @escaping (String) -> Void = { _ in },
            onSubmitBatch: (([String]) -> Void)? = nil,
            vocabulary: (@MainActor () -> CompletionVocabulary)? = nil
        ) throws {
            let root = AnyView(CommandInputView(
                onSubmit: onSubmit,
                onSubmitBatch: onSubmitBatch,
                vocabulary: vocabulary
            )
            .frame(width: 320, height: 80))
            host = NSHostingView(rootView: root)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            guard let found = host.firstCommandInput() else {
                throw CommandInputTestError.missingTextView
            }
            textView = found
        }

        func setText(_ text: String) {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    private enum CommandInputTestError: Error {
        case missingTextView
    }

    private extension NSView {
        func firstCommandInput() -> AutoFocusCommandTextView? {
            if let textView = self as? AutoFocusCommandTextView {
                return textView
            }
            for subview in subviews {
                if let found = subview.firstCommandInput() {
                    return found
                }
            }
            return nil
        }
    }
#endif
