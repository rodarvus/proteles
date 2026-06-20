import Foundation

/// The inbound-line trigger-processing entry points, split out of
/// ``ScriptEngine`` to keep that file within the 600-line budget. Triggers match
/// the line in ``TriggerEngine/process(_:)`` order; each firing's send/script
/// runs inline here (in sequence order), so a fired script can halt the rest of
/// the line via `StopEvaluatingTriggers` (``ScriptEngine/stopTriggerEvaluation``).
public extension ScriptEngine {
    /// Run `line` through the triggers, returning the gag decision and the
    /// effects (trigger sends + script effects, in order). Script errors
    /// surface as red notes rather than aborting.
    func process(line text: String) async -> LineDisposition {
        await process(Line(id: LineID(0), text: text))
    }

    /// Styled-line entry point: triggers match `line.text` (and get its colour
    /// runs as `styles`); native plugins receive the full styled ``Line``.
    func process(_ line: Line) async -> LineDisposition {
        // While suspended (Note mode), lines pass through untouched.
        if suspended { return LineDisposition() }
        var disposition = LineDisposition()
        // Highlights collected from firings, applied to the *displayed* line
        // after native plugins have had their say (they may replace it).
        var highlights: [(highlight: TriggerHighlight, matchRange: Range<Int>?)] = []
        // Cleared each line; a fired trigger's script may set it via
        // StopEvaluatingTriggers to skip the remaining firings (see below).
        stopTriggerEvaluation = false
        for firing in triggers.process(line.text) {
            if firing.gag { disposition.gag = true }
            if let highlight = firing.highlight {
                highlights.append((highlight, firing.match.utf16Range))
            }
            if let send = firing.send, !send.isEmpty {
                // D-105: route the expanded send per the trigger's target.
                disposition.effects.append(Self.sendEffect(send, target: firing.target))
            }
            if let script = firing.script {
                let owner = automationOwners[firing.triggerID]
                // Plugin triggers: %1/%0/%<name> in the body are substituted with
                // (Lua-escaped) captures before it runs; user scripts (no owner)
                // run verbatim so a literal `%` survives.
                let body = owner == nil ? script : firing.match.expandForScript(script)
                await disposition.effects.append(contentsOf: runOwnedScript(
                    body,
                    owner: owner,
                    matches: firing.match.captures,
                    named: firing.match.named,
                    styles: ScriptStyleRun.mushStyles(text: line.text, runs: line.runs)
                ))
            }
            // StopEvaluatingTriggers: a fired script halted the line — don't
            // apply the remaining (later-sequence) firings.
            if stopTriggerEvaluation { break }
        }
        // Fold native plugins' reactions (gag / effects / a rewritten line).
        let native = nativePlugins.onLine(line)
        if native.gag { disposition.gag = true }
        disposition.effects.append(contentsOf: native.effects)
        disposition.replacement = native.replacement
        // Trigger highlights (D-105) restyle whatever will be displayed.
        return Self.applyingHighlights(highlights, to: disposition, original: line)
    }
}
