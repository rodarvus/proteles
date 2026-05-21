import Foundation

/// Command-line history with up/down recall and prefix autocompletion —
/// the model behind the input box (PLAN.md §8.4).
///
/// Pure value type so it's unit-testable without the UI. The view layer
/// owns one instance, feeds it submitted commands, and asks it what to
/// show on Up / Down / Tab.
///
/// Behaviour follows Mudlet's command line (`src/TCommandLine.cpp`):
///
///   - **Global dedup.** Re-submitting a command moves it to the most
///     recent slot rather than creating a duplicate.
///   - **Clamped navigation.** Up stops at the oldest entry; Down past the
///     newest restores the line you were typing (the "draft") — it does
///     not wrap.
///   - **Draft preservation.** The partially-typed line is stashed when
///     you first press Up and restored when you Down back past the end.
///
/// Autocompletion is whole-line prefix matching against history, because
/// "completing a command" means "repeat one you've run before." Commands
/// whose first word is a communication/chat verb (``communicationCommands``)
/// are never offered — you don't re-run a half-typed `tell`.
public struct CommandHistory: Sendable, Equatable {
    /// Stored commands, oldest first. Bounded by ``capacity`` and free of
    /// adjacent or distant duplicates.
    public private(set) var entries: [String] = []

    /// Maximum number of remembered commands. Matches MUSHclient's
    /// default (`history_lines`).
    public let capacity: Int

    /// First-word command names that are excluded from autocompletion.
    /// Lowercased.
    public let completionExclusions: Set<String>

    /// `nil` when not navigating (the field holds the live/draft line);
    /// otherwise an index into ``entries``.
    private var navigationIndex: Int?

    /// The line the user was typing before they started pressing Up,
    /// restored when they Down back past the newest entry.
    private var draft: String = ""

    public init(
        capacity: Int = 1000,
        completionExclusions: Set<String> = CommandHistory.communicationCommands
    ) {
        self.capacity = max(capacity, 1)
        self.completionExclusions = completionExclusions
    }

    // MARK: - Recording

    /// Record a submitted command. Empty / whitespace-only commands are
    /// ignored (a bare Enter is a prompt nudge, not a command). Existing
    /// duplicates are removed so the command lands as the most recent
    /// entry. Resets navigation to the live line.
    public mutating func record(_ command: String) {
        defer { resetNavigation() }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        entries.removeAll { $0 == command }
        entries.append(command)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    // MARK: - Recall

    /// Move toward older history (the Up arrow). `currentText` is what the
    /// field holds now; on the first step it's stashed as the draft.
    /// Returns the text to display, or `nil` if there's nothing to show
    /// (empty history, or already at the oldest entry).
    public mutating func recallPrevious(currentText: String) -> String? {
        guard !entries.isEmpty else { return nil }
        switch navigationIndex {
        case nil:
            draft = currentText
            let index = entries.count - 1
            navigationIndex = index
            return entries[index]
        case .some(let index) where index > 0:
            navigationIndex = index - 1
            return entries[index - 1]
        default:
            return nil // clamp at the oldest entry
        }
    }

    /// Move toward newer history (the Down arrow). Returns the text to
    /// display — a newer entry, or the restored draft once you step past
    /// the newest entry. `nil` when not currently navigating.
    public mutating func recallNext() -> String? {
        guard let index = navigationIndex else { return nil }
        if index < entries.count - 1 {
            navigationIndex = index + 1
            return entries[index + 1]
        }
        // Stepped past the newest entry: back to the live draft line.
        navigationIndex = nil
        let restored = draft
        draft = ""
        return restored
    }

    /// True while Up/Down is walking history (not on the live line).
    public var isNavigating: Bool {
        navigationIndex != nil
    }

    /// Abandon navigation and forget the stashed draft. Call when the user
    /// edits the field by typing.
    public mutating func resetNavigation() {
        navigationIndex = nil
        draft = ""
    }

    // MARK: - Completion

    /// Whole-line completions for `prefix`, most-recent first and unique.
    ///
    /// A candidate qualifies when it begins with `prefix` (case-insensitive),
    /// is strictly longer than `prefix` (so an already-complete line isn't
    /// "completed" to itself), and its first word is not in
    /// ``completionExclusions``. An empty / whitespace-only prefix yields
    /// nothing.
    public func completions(for prefix: String) -> [String] {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let needle = prefix.lowercased()

        var seen: Set<String> = []
        var result: [String] = []
        for entry in entries.reversed() {
            let lower = entry.lowercased()
            guard lower.hasPrefix(needle), entry.count > prefix.count else { continue }
            guard !isExcludedFromCompletion(entry) else { continue }
            guard seen.insert(entry).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    /// True if `command`'s first word is a communication/chat verb that
    /// should never be auto-completed.
    public func isExcludedFromCompletion(_ command: String) -> Bool {
        guard let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        return completionExclusions.contains(first.lowercased())
    }
}

public extension CommandHistory {
    /// Aardwolf communication / chat command words excluded from
    /// autocompletion. Sourced from the channel list in
    /// `aardwolfclientpackage/.../aard_channels_fiendish.xml` plus the
    /// directed-message verbs (`tell`/`reply`/`whisper`/`page` family),
    /// which carry private message bodies you never want re-offered.
    static let communicationCommands: Set<String> = [
        // Directed / private messaging.
        "tell", "reply", "whisper", "page", "ask", "gtell", "ptell",
        "ctell", "clantell", "racetell", "rtell",
        // Says / emotes.
        "say", "sayto", "'", "emote", "emoteto", "pmote", "yell",
        // Aardwolf channels.
        "answer", "auction", "barter", "cant", "chant", "chat", "claninfo",
        "clantalk", "clan", "commune", "curse", "debate", "dtell", "epics",
        "ftalk", "gametalk", "gclan", "gossip", "grapevine", "gratz",
        "group", "helper", "immtalk", "lasertag", "ltalk", "mafiainfo",
        "market", "mchat", "mobsay", "music", "newbie", "snewbie", "pchat",
        "ptalk", "question", "quote", "racetalk", "rauction", "restores",
        "rp", "sports", "spouse", "tech", "telepathy", "tier", "tiertalk",
        "trivia", "wangrp", "wardrums", "nobletalk", "gsocial"
    ]
}
