import Foundation

/// Pure helpers for ``ScriptEngine/process(_:)`` (split out for the file/
/// complexity budgets): turning a trigger firing's send into the right
/// ``ScriptEffect`` for its target, and folding collected highlights into
/// the displayed line (D-105).
extension ScriptEngine {
    /// What to do with a processed line. (Declared here, not in the actor
    /// body, purely for `ScriptEngine.swift`'s file-length budget.)
    public struct LineDisposition: Sendable, Equatable {
        /// Omit the line from output.
        public var gag: Bool
        /// Effects produced by matched triggers / their scripts, in order.
        public var effects: [ScriptEffect]
        /// A rewritten line to display *instead* of the original (e.g. a
        /// text substitution), preserving the original id/timestamp. `nil`
        /// leaves the incoming line unchanged.
        public var replacement: Line?
        /// Effects from ``SemanticEvent`` consumers (#82), kept **separate**
        /// from ``effects`` because they are applied under a different
        /// condition: ordinary trigger effects run whether or not the line is
        /// displayed, while these run **only if the line survives every gag**.
        ///
        /// They ride back on this value rather than being fetched in a second
        /// pass. `process(_:)` already runs on the engine actor, so classifying
        /// there costs nothing extra, whereas re-entering the actor from the
        /// displayed seam added a round-trip per line — measurably so in a kill
        /// burst (#85, and the regression recorded in S0A_WIRING_PROPOSAL.md).
        public var semanticEffects: [ScriptEffect]
        /// Effects of the line's **tag-sourced** events, applied whether or
        /// not the line is displayed (D-128). A tag line is machine data whose
        /// hiding is the norm — the tag-hide preference, and plugins'
        /// `omit_from_output` — so whether the player saw it says nothing about
        /// whether the event happened. The displayed-only rule above stays for
        /// prose, which is what D-118's displayed-path rule protects.
        public var structuralEffects: [ScriptEffect]

        public init(
            gag: Bool = false,
            effects: [ScriptEffect] = [],
            replacement: Line? = nil,
            semanticEffects: [ScriptEffect] = [],
            structuralEffects: [ScriptEffect] = []
        ) {
            self.gag = gag
            self.effects = effects
            self.replacement = replacement
            self.semanticEffects = semanticEffects
            self.structuralEffects = structuralEffects
        }
    }

    /// The effect for an expanded trigger send, per its ``TriggerTarget``.
    static func sendEffect(_ send: String, target: TriggerTarget) -> ScriptEffect {
        switch target {
        case .world: .send(send)
        case .execute: .execute(send)
        case .output: .note(text: send, foreground: nil, background: nil)
        }
    }

    /// Apply trigger highlights to whatever line will be displayed. A span
    /// highlight only makes sense against the text it was matched on — if a
    /// substitution rewrote the line, fall back to the whole line.
    static func applyingHighlights(
        _ highlights: [(highlight: TriggerHighlight, matchRange: Range<Int>?)],
        to disposition: LineDisposition,
        original line: Line
    ) -> LineDisposition {
        guard !highlights.isEmpty, !disposition.gag else { return disposition }
        var updated = disposition
        var display = disposition.replacement ?? line
        let textChanged = display.text != line.text
        for (highlight, range) in highlights {
            display = LineHighlighter.apply(
                highlight, to: display, matchRange: textChanged ? nil : range
            )
        }
        updated.replacement = display
        return updated
    }
}
