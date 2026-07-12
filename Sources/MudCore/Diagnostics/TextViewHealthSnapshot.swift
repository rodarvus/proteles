import Foundation

/// Sanitized geometry/state for a text surface.
///
/// This deliberately carries counts and layout measurements only: no rendered
/// text, no ANSI payloads, and no channel names.
public struct TextViewHealthSnapshot: Sendable, Equatable {
    public let surface: String
    public let reason: String
    public let renderedLines: Int
    public let storageUTF16Length: Int
    public let textViewBoundsHeight: Double
    public let documentHeight: Double
    public let visibleOriginY: Double
    public let visibleHeight: Double
    public let distanceFromBottom: Double
    public let isPinnedToBottom: Bool
    public let isViewHidden: Bool
    public let hasWindow: Bool
    public let textViewBoundsWidth: Double
    public let documentWidth: Double
    public let visibleOriginX: Double
    public let visibleWidth: Double
    public let textContainerWidth: Double
    public let usesTextLayoutManager: Bool
    public let viewportStartUTF16: Int?
    public let viewportEndUTF16: Int?
    public let topLayoutFragmentState: Int?
    public let topVisualLineCount: Int?
    public let extra: String

    public init(
        surface: String,
        reason: String,
        renderedLines: Int,
        storageUTF16Length: Int,
        textViewBoundsHeight: Double,
        documentHeight: Double,
        visibleOriginY: Double,
        visibleHeight: Double,
        distanceFromBottom: Double,
        isPinnedToBottom: Bool,
        isViewHidden: Bool,
        hasWindow: Bool,
        textViewBoundsWidth: Double = 0,
        documentWidth: Double = 0,
        visibleOriginX: Double = 0,
        visibleWidth: Double = 0,
        textContainerWidth: Double = 0,
        usesTextLayoutManager: Bool = false,
        viewportStartUTF16: Int? = nil,
        viewportEndUTF16: Int? = nil,
        topLayoutFragmentState: Int? = nil,
        topVisualLineCount: Int? = nil,
        extra: String = ""
    ) {
        self.surface = surface
        self.reason = reason
        self.renderedLines = renderedLines
        self.storageUTF16Length = storageUTF16Length
        self.textViewBoundsHeight = textViewBoundsHeight
        self.documentHeight = documentHeight
        self.visibleOriginY = visibleOriginY
        self.visibleHeight = visibleHeight
        self.distanceFromBottom = distanceFromBottom
        self.isPinnedToBottom = isPinnedToBottom
        self.isViewHidden = isViewHidden
        self.hasWindow = hasWindow
        self.textViewBoundsWidth = textViewBoundsWidth
        self.documentWidth = documentWidth
        self.visibleOriginX = visibleOriginX
        self.visibleWidth = visibleWidth
        self.textContainerWidth = textContainerWidth
        self.usesTextLayoutManager = usesTextLayoutManager
        self.viewportStartUTF16 = viewportStartUTF16
        self.viewportEndUTF16 = viewportEndUTF16
        self.topLayoutFragmentState = topLayoutFragmentState
        self.topVisualLineCount = topVisualLineCount
        self.extra = extra
    }

    public func transcriptNote(context: String? = nil) -> String {
        let label = sanitizedLabel(context ?? reason)
        let source = context == nil || context == reason
            ? ""
            : " source \(sanitizedLabel(reason))"
        let viewport = viewportStartUTF16.map { start in
            " viewport \(start)..\(viewportEndUTF16 ?? start)"
        } ?? " viewport nil"
        let fragment = topLayoutFragmentState.map { state in
            " fragment \(state)/\(topVisualLineCount ?? 0)"
        } ?? " fragment nil"
        let suffix = extra.isEmpty ? "" : " \(extra)"
        return "text-health: \(sanitizedLabel(surface)) \(label) "
            + "lines \(renderedLines) storage \(storageUTF16Length)u16 "
            + "boundsW \(format(textViewBoundsWidth)) "
            + "boundsH \(format(textViewBoundsHeight)) "
            + "docW \(format(documentWidth)) "
            + "docH \(format(documentHeight)) "
            + "visibleX \(format(visibleOriginX)) "
            + "visibleY \(format(visibleOriginY)) "
            + "visibleW \(format(visibleWidth)) "
            + "visibleH \(format(visibleHeight)) "
            + "bottom \(format(distanceFromBottom)) "
            + "pinned \(isPinnedToBottom) hidden \(isViewHidden) "
            + "window \(hasWindow) containerW \(format(textContainerWidth)) "
            + "textkit2 \(usesTextLayoutManager)\(viewport)\(fragment)"
            + "\(source)\(suffix)"
    }

    private func sanitizedLabel(_ value: String) -> String {
        value
            .map { character in
                if character.isLetter || character.isNumber || "-_. /".contains(character) {
                    return character
                }
                return "-"
            }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
