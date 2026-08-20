#if os(macOS)
    import AppKit

    @MainActor
    enum ChatTextStorageUpdater {
        static func rebuild(
            storage: NSTextStorage,
            document: ChatBuiltDocument,
            renderedLines: inout [ChatRenderedLineSpan]
        ) {
            storage.setAttributedString(document.attributed)
            renderedLines = document.renderedLines
        }

        static func applyIncremental(
            storage: NSTextStorage,
            removeFirst: Int,
            appended: ChatBuiltDocument,
            renderedLines: inout [ChatRenderedLineSpan]
        ) {
            precondition(removeFirst <= renderedLines.count)
            storage.beginEditing()
            defer { storage.endEditing() }

            if removeFirst > 0 {
                let removedLength = renderedLines[..<removeFirst]
                    .reduce(0) { $0 + $1.utf16Length }
                storage.deleteCharacters(in: NSRange(location: 0, length: removedLength))
                renderedLines.removeFirst(removeFirst)
            }
            if !renderedLines.isEmpty, !appended.renderedLines.isEmpty {
                storage.append(NSAttributedString(string: "\n"))
                renderedLines[renderedLines.count - 1].utf16Length += 1
            }
            storage.append(appended.attributed)
            renderedLines.append(contentsOf: appended.renderedLines)
        }
    }
#endif
