import Foundation
import MudCore

/// Drives the **Help** panel: receives captured ``HelpArticle``s from the
/// session, keeps a back/forward history, and renders the current article into
/// a ``ScrollbackStore`` the panel's output view displays. Clicking a help
/// cross-reference (a `.sendCommand("help <topic>")` link) and submitting the
/// search field both route through ``onCommand`` to the session, whose reply is
/// captured back as the next article.
///
/// `ScrollbackStore` has no clear, so each displayed article gets a *fresh*
/// store and a new ``renderToken``; the view swaps its output view on the token.
@MainActor
@Observable
public final class HelpPanelModel {
    /// The store backing the current article (a new one per navigation).
    public private(set) var store = ScrollbackStore()
    /// Changes whenever ``store`` is replaced, so the view recreates its output.
    public private(set) var renderToken = UUID()
    /// The current article's heading (panel title / toolbar label).
    public private(set) var title = "Help"
    /// True once at least one article has been shown (drives the empty state).
    public private(set) var hasContent = false

    /// Routes link clicks + the search field to the session (`session.send`).
    public var onCommand: ((String) -> Void)?

    private var history: [HelpArticle] = []
    private var index = -1

    public init() {}

    public var canGoBack: Bool {
        index > 0
    }

    public var canGoForward: Bool {
        index >= 0 && index < history.count - 1
    }

    /// A freshly captured article: truncate any forward history, push, show it.
    public func apply(_ article: HelpArticle) async {
        if index < history.count - 1 {
            history.removeSubrange((index + 1)...)
        }
        history.append(article)
        index = history.count - 1
        await display(article)
    }

    public func back() async {
        guard canGoBack else { return }
        index -= 1
        await display(history[index])
    }

    public func forward() async {
        guard canGoForward else { return }
        index += 1
        await display(history[index])
    }

    /// Submit a `help search <query>` (routed to the session; the reply is
    /// captured as the next article).
    public func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommand?("help search \(trimmed)")
    }

    private func display(_ article: HelpArticle) async {
        let fresh = ScrollbackStore()
        for line in article.lines {
            _ = await fresh.append(line)
        }
        store = fresh
        renderToken = UUID()
        title = article.title
        hasContent = true
    }
}
