import SwiftUI

#if os(macOS)
    import AppKit

    extension CommandField.Coordinator {
        func replaceInput(_ text: String) {
            endCycle()
            history.resetNavigation()
            setText(text)
        }

        func pasteInput(_ text: String) {
            guard let textView else { return }
            endCycle()
            history.resetNavigation()
            hideGhost()

            let current = textView.string as NSString
            let selected = textView.selectedRange()
            let location = Swift.min(selected.location, current.length)
            let length = Swift.min(selected.length, current.length - location)
            let safeRange = NSRange(location: location, length: length)
            let next = current.replacingCharacters(in: safeRange, with: text)
            let caret = safeRange.location + (text as NSString).length

            programmaticEdit = true
            textView.string = next
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            programmaticEdit = false
            updateHeight()
            resetScrollIfAllContentFits()
            scrollCaretToVisible()
            DispatchQueue.main.async { [weak self] in
                self?.resetScrollIfAllContentFits()
                self?.scrollCaretToVisible()
            }
        }

        func selectInput(startColumn: Int, endColumn: Int) {
            guard let textView else { return }
            endCycle()
            history.resetNavigation()
            hideGhost()

            let length = (textView.string as NSString).length
            let start = Swift.min(Swift.max(0, startColumn - 1), length)
            let end = endColumn < 0 ? length : Swift.min(Swift.max(0, endColumn), length)
            let lower = Swift.min(start, end)
            let upper = Swift.max(start, end)

            textView.setSelectedRange(NSRange(location: lower, length: upper - lower))
            scrollCaretToVisible()
        }
    }
#endif
