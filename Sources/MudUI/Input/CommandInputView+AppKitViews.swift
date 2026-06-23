import MudCore
import SwiftUI

#if os(macOS)
    import AppKit

    extension CommandField {
        /// SwiftUI re-invokes this on every state change; re-point the coordinator
        /// callbacks + re-apply the live text-editing policy (spell-check, etc.).
        func updateNSView(_: NSView, context: Context) {
            context.coordinator.onSubmit = onSubmit
            context.coordinator.onSubmitBatch = onSubmitBatch
            context.coordinator.vocabulary = vocabulary
            context.coordinator.ghostHintEnabled = ghostHint
            context.coordinator.autoRepeatLastCommand = autoRepeatLastCommand
            context.coordinator.onHeightChange = onHeightChange
            context.coordinator.bindCommandInputEdits(commandInputEdits)
            if let textView = context.coordinator.textView {
                textView.onMacroKey = onMacroKey
                textView.spellChecking = spellChecking
                textView.applyTextEditingPolicy() // re-apply if toggled while focused
                context.coordinator.lineHeight = Self.lineHeight(for: textView.font)
                context.coordinator.updateHeight()
            }
            if !ghostHint { context.coordinator.hideGhost() }
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            return scrollView
        }

        func makeTextView(context: Context) -> AutoFocusCommandTextView {
            let textView = AutoFocusCommandTextView(frame: .zero)
            textView.onMacroKey = onMacroKey
            textView.spellChecking = spellChecking
            textView.delegate = context.coordinator
            textView.commandHandler = { [weak coordinator = context.coordinator] selector in
                coordinator?.handleCommand(selector) ?? false
            }
            textView.replaceInput = { [weak coordinator = context.coordinator] text in
                coordinator?.replaceInput(text)
            }
            configureIdentity(for: textView)
            configureEditing(for: textView)
            return textView
        }

        func makeGhostLabel(font: NSFont?) -> NSTextField {
            let ghost = NSTextField(labelWithString: "")
            ghost.font = font
            ghost.textColor = .tertiaryLabelColor
            ghost.lineBreakMode = .byClipping
            ghost.isHidden = true
            ghost.refusesFirstResponder = true
            ghost.drawsBackground = false
            ghost.isBezeled = false
            ghost.isBordered = false
            ghost.controlSize = .regular
            ghost.cell?.usesSingleLineMode = true
            ghost.setAccessibilityElement(false)
            return ghost
        }

        func makeContainer(
            scrollView: NSScrollView,
            ghost: NSTextField,
            context: Context
        ) -> CommandInputContainerView {
            let container = CommandInputContainerView()
            container.onLayout = { [weak coordinator = context.coordinator] in
                coordinator?.updateHeight()
            }
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scrollView)
            container.addSubview(ghost)
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            return container
        }

        func configureCoordinator(
            _ coordinator: Coordinator,
            container: NSView,
            scrollView: NSScrollView,
            textView: AutoFocusCommandTextView,
            ghost: NSTextField
        ) {
            coordinator.container = container
            coordinator.scrollView = scrollView
            coordinator.textView = textView
            coordinator.ghost = ghost
            coordinator.ghostHintEnabled = ghostHint
            coordinator.onHeightChange = onHeightChange
            coordinator.lineHeight = Self.lineHeight(for: textView.font)
            coordinator.maxVisualLines = Self.visualLineCap
        }

        private func configureIdentity(for textView: AutoFocusCommandTextView) {
            textView.identifier = NSUserInterfaceItemIdentifier("proteles.command")
            textView.setAccessibilityIdentifier("command-input")
            textView.setAccessibilityLabel("Command input")
        }

        private func configureEditing(for textView: AutoFocusCommandTextView) {
            textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            textView.drawsBackground = false
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.usesFontPanel = false
            textView.isEditable = true
            textView.isSelectable = true
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = Self.textInset
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.heightTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: 1,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.lineBreakMode = .byWordWrapping
            textView.applyTextEditingPolicy()
        }
    }

    extension CommandField.Coordinator {
        func bindCommandInputEdits(_ stream: AsyncStream<CommandInputEdit>?) {
            guard commandInputTask == nil, let stream else { return }
            commandInputTask = Task { @MainActor [weak self] in
                for await edit in stream {
                    switch edit.kind {
                    case .set:
                        self?.replaceInput(edit.text)
                    case .paste:
                        self?.pasteInput(edit.text)
                    case .select:
                        self?.selectInput(startColumn: edit.startColumn, endColumn: edit.endColumn)
                    }
                }
            }
        }
    }
#endif
