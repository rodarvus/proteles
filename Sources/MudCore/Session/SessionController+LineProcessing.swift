import Foundation

/// Inbound line processing through scripts/native plugins and then display.
/// Split from `SessionController+Scripting.swift` so instrumentation can stay
/// readable without pushing that file over the strict file-length budget.
extension SessionController {
    /// Run a received line through the script engine (if any), then append
    /// it unless a trigger gagged it. Trigger sends/echoes are applied
    /// afterwards so echoes land just below the line that produced them.
    @discardableResult
    func appendLineThroughScripts(_ line: Line) async -> LineProcessingSummary {
        let walked = await measureSessionPhase(
            "session.lines.walk-marker",
            events: 1,
            thresholdMS: 50
        ) {
            await handleWalkMarker(line)
        }
        if walked { return LineProcessingSummary(gagged: 1) }
        let capturedHelp = PerformanceProbe.shared.measure(
            "session.lines.help-capture",
            events: 1,
            thresholdMS: 50
        ) {
            helpCaptureEnabled && captureHelpLine(line)
        }
        if capturedHelp { return LineProcessingSummary(gagged: 1) }
        let capturedMarket = PerformanceProbe.shared.measure(
            "session.lines.market-capture",
            events: 1,
            thresholdMS: 50
        ) {
            marketCaptureEnabled && captureMarketLine(line)
        }
        if capturedMarket { return LineProcessingSummary(gagged: 1) }
        let omitBlank = Self.omitsFromOutput(line, omitBlankLines: omitBlankLines)
        guard let scriptEngine else {
            return await appendLineWithoutGenericScripts(line, omitBlank: omitBlank)
        }
        return await appendLineWithGenericScripts(
            line,
            scriptEngine: scriptEngine,
            omitBlank: omitBlank
        )
    }

    private func appendLineWithoutGenericScripts(
        _ line: Line,
        omitBlank: Bool
    ) async -> LineProcessingSummary {
        let sndGag = await measuredSearchAndDestroyGag(line)
        if !sndGag, !omitBlank {
            await measureSessionPhase(
                "session.lines.display",
                events: 1,
                thresholdMS: 50
            ) {
                await scrollbackStore.append(line)
            }
            return LineProcessingSummary(displayed: 1)
        }
        return LineProcessingSummary(gagged: 1)
    }

    private func appendLineWithGenericScripts(
        _ line: Line,
        scriptEngine: ScriptEngine,
        omitBlank: Bool
    ) async -> LineProcessingSummary {
        let disposition = await measureSessionPhase(
            "session.lines.script-engine",
            events: 1,
            thresholdMS: 50
        ) {
            await scriptEngine.process(line)
        }
        let sndGag = await measuredSearchAndDestroyGag(line)
        let (outLine, richExitsGag) = measuredRichExitsLine(
            disposition.replacement ?? line,
            source: line
        )
        let wishGag = PerformanceProbe.shared.measure(
            "session.lines.wishprobe",
            events: 1,
            thresholdMS: 50
        ) {
            consumeWishProbeGag(line)
        }
        let tagResult = measuredTagCleanLine(outLine)
        let shouldDisplay = !disposition.gag
            && !sndGag
            && !omitBlank
            && !richExitsGag
            && !wishGag
            && !tagResult.gag
        if shouldDisplay {
            return await finishDisplayedLine(tagResult.line, effects: disposition.effects)
        }
        return await finishGaggedLine(
            line,
            disposition: disposition,
            reasons: LineGagReasons(
                script: disposition.gag,
                snd: sndGag,
                richExits: richExitsGag,
                blank: omitBlank,
                wishProbe: wishGag,
                tag: tagResult.gag
            )
        )
    }

    private func measuredSearchAndDestroyGag(_ line: Line) async -> Bool {
        await measureSessionPhase(
            "session.lines.snd",
            events: 1,
            thresholdMS: 50
        ) {
            await applySearchAndDestroyLine(line)
        }
    }

    private func measuredRichExitsLine(_ line: Line, source: Line) -> (Line, Bool) {
        PerformanceProbe.shared.measure(
            "session.lines.rich-exits",
            events: 1,
            thresholdMS: 50
        ) {
            applyRichExits(line, source: source)
        }
    }

    private func measuredTagCleanLine(_ line: Line) -> (line: Line, gag: Bool) {
        let shouldCleanTag = PerformanceProbe.shared.measure(
            "session.lines.tag-check",
            events: 1,
            thresholdMS: 50
        ) {
            gagTagLines && Self.isAardwolfTagLine(line.text)
        }
        guard shouldCleanTag else { return (line, false) }
        guard let stripped = AardwolfTags.displayLine(for: line) else {
            return (line, true)
        }
        return (stripped, false)
    }

    private func finishDisplayedLine(
        _ line: Line,
        effects: [ScriptEffect]
    ) async -> LineProcessingSummary {
        await measureSessionPhase("session.lines.display", events: 1, thresholdMS: 50) {
            await recordDisplayed(line, kind: .mud)
        }
        let screendrawEffects = await measureSessionPhase(
            "session.lines.screendraw",
            events: 1,
            thresholdMS: 50
        ) {
            await scriptEngine?.fireOnPluginScreendraw(type: 0, log: true, line: line.text) ?? []
        }
        PerformanceProbe.shared.measure("session.lines.notify", events: 1, thresholdMS: 50) {
            notifyForOutput(line.text)
        }
        PerformanceProbe.shared.measure("session.lines.speech", events: 1, thresholdMS: 50) {
            speakForOutput(line.text)
        }
        await applyMeasuredEffects(screendrawEffects + effects)
        return LineProcessingSummary(displayed: 1, effects: screendrawEffects.count + effects.count)
    }

    private func finishGaggedLine(
        _ line: Line,
        disposition: ScriptEngine.LineDisposition,
        reasons: LineGagReasons
    ) async -> LineProcessingSummary {
        logTranscript(.gag, "[\(reasons.label)] \(line.text)")
        await applyMeasuredEffects(disposition.effects)
        return LineProcessingSummary(gagged: 1, effects: disposition.effects.count)
    }

    private func applyMeasuredEffects(_ effects: [ScriptEffect]) async {
        await measureSessionPhase(
            "session.lines.effects",
            events: effects.count,
            thresholdMS: 50
        ) {
            await applyScriptEffects(effects)
        }
        await measureSessionPhase(
            "session.lines.timer-rearm",
            events: 1,
            thresholdMS: 50
        ) {
            await rearmTimerLoopIfScriptScheduled()
        }
    }
}

private struct LineGagReasons {
    let script: Bool
    let snd: Bool
    let richExits: Bool
    let blank: Bool
    let wishProbe: Bool
    let tag: Bool

    var label: String {
        [
            script ? "script" : nil,
            snd ? "snd" : nil,
            richExits ? "richexits" : nil,
            blank ? "blank" : nil,
            wishProbe ? "wishprobe" : nil,
            tag ? "tag" : nil
        ].compactMap(\.self).joined(separator: "+")
    }
}
