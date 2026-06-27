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
        // Cleared each line; a fired trigger's script may set it via
        // StopEvaluatingTriggers to skip the remaining firings (see below).
        stopTriggerEvaluation = false
        let firings = measureScriptPhase(
            "session.script.trigger-match",
            thresholdMS: 50
        ) {
            triggers.process(line.text)
        }
        recordTriggerBurst(firings)
        var result = await processTriggerFirings(firings, line: line)
        let native = measureScriptPhase(
            "session.script.native-line",
            thresholdMS: 50
        ) {
            nativePlugins.onLine(line)
        }
        if native.gag { result.disposition.gag = true }
        result.disposition.effects.append(contentsOf: native.effects)
        result.disposition.replacement = native.replacement
        // Trigger highlights (D-105) restyle whatever will be displayed.
        return measureScriptPhase(
            "session.script.highlights",
            events: result.highlights.count,
            thresholdMS: 50
        ) {
            Self.applyingHighlights(result.highlights, to: result.disposition, original: line)
        }
    }

    private func processTriggerFirings(
        _ firings: [TriggerFiring],
        line: Line
    ) async -> TriggerProcessingResult {
        let triggerStart = ContinuousClock.now
        var disposition = LineDisposition()
        // Highlights collected from firings, applied to the *displayed* line
        // after native plugins have had their say (they may replace it).
        var highlights: [(highlight: TriggerHighlight, matchRange: Range<Int>?)] = []
        for firing in firings {
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
                let phase = owner == nil
                    ? "session.script.trigger-script.user"
                    : "session.script.trigger-script.plugin"
                let effects = await measureScriptPhase(
                    phase,
                    events: 1,
                    thresholdMS: 50
                ) {
                    await runOwnedScript(
                        body,
                        owner: owner,
                        matches: firing.match.captures,
                        named: firing.match.named,
                        styles: ScriptStyleRun.mushStyles(text: line.text, runs: line.runs)
                    )
                }
                disposition.effects.append(contentsOf: effects)
            }
            // StopEvaluatingTriggers: a fired script halted the line — don't
            // apply the remaining (later-sequence) firings.
            if stopTriggerEvaluation { break }
        }
        recordScriptPhase(
            "session.script.trigger-loop",
            duration: ContinuousClock.now - triggerStart,
            events: firings.count,
            thresholdMS: 50
        )
        return TriggerProcessingResult(disposition: disposition, highlights: highlights)
    }

    private func measureScriptPhase<T>(
        _ phase: String,
        events: Int = 1,
        thresholdMS: Int,
        _ body: () async -> T
    ) async -> T {
        guard PerformanceProbe.shared.recordsAttribution else { return await body() }
        let start = ContinuousClock.now
        let value = await body()
        recordScriptPhase(
            phase,
            duration: ContinuousClock.now - start,
            events: events,
            thresholdMS: thresholdMS
        )
        return value
    }

    private func measureScriptPhase<T>(
        _ phase: String,
        events: Int = 1,
        thresholdMS: Int,
        _ body: () -> T
    ) -> T {
        PerformanceProbe.shared.measure(
            phase,
            events: events,
            thresholdMS: thresholdMS,
            body
        )
    }

    private func recordScriptPhase(
        _ phase: String,
        duration: Duration,
        events: Int,
        thresholdMS: Int
    ) {
        PerformanceProbe.shared.recordPhase(
            phase,
            duration: duration,
            events: events,
            thresholdMS: thresholdMS
        )
    }

    private func recordTriggerBurst(_ firings: [TriggerFiring]) {
        guard !firings.isEmpty else { return }
        PerformanceProbe.shared.recordEventSummary(
            "session.script.triggers",
            events: firings.count,
            fields: [
                ("scripts", firings.count { $0.script != nil }),
                ("sends", firings.count { $0.send?.isEmpty == false }),
                ("gags", firings.count(where: \.gag)),
                ("highlights", firings.count { $0.highlight != nil })
            ],
            thresholdEvents: 5
        )
    }
}

private struct TriggerProcessingResult {
    var disposition: ScriptEngine.LineDisposition
    var highlights: [(highlight: TriggerHighlight, matchRange: Range<Int>?)]
}
