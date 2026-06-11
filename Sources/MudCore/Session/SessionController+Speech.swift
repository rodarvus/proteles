import Foundation

/// The TTS pipeline's session half (#9), mirroring notifications: displayed
/// lines run through the pure ``SpeechFilter`` and surviving text is yielded
/// on ``SessionController/speechRequests`` for the app's speech controller.
/// Speaking at *display* time — not in a plugin's `onLine` — is what keeps
/// the map, gauges, and everything plugins gag out of the spoken stream.
public extension SessionController {
    /// Buffer + (mode permitting) speak one displayed line. Called right
    /// after the line lands in the scrollback.
    internal func speakForOutput(_ text: String) {
        recentDisplayedLines.append(text)
        if recentDisplayedLines.count > Self.recentDisplayedLimit {
            recentDisplayedLines.removeFirst(recentDisplayedLines.count - Self.recentDisplayedLimit)
        }
        guard speechMode != .off else { return }
        // Prompts are status, not prose (live-test round 2): instead of
        // reading the whole prompt line, speak only the vitals that CHANGED —
        // hp first, then mana; movement never ("almost never a concern").
        // Walking rooms with stable hp/mana is therefore silent.
        if speechMode == .everything, let vitals = SpeechFilter.promptVitals(in: text) {
            speakVitalsDelta(vitals)
            return
        }
        guard let decision = SpeechFilter.decision(forDisplayedLine: text, mode: speechMode)
        else { return }
        // Consecutive-repeat suppression (screen-reader style): an identical
        // line right after itself reads once. Any different line in between
        // resets, so alternating combat lines still all speak.
        guard decision.text != lastSpokenLineText else { return }
        lastSpokenLineText = decision.text
        speechRequestsContinuation.yield(.speak(text: decision.text, interrupt: decision.interrupt))
    }

    /// Speak a prompt's changed vitals: the very first prompt orients with
    /// hp + mana; after that, only components that differ from the last
    /// SPOKEN values are read ("hp 1180", "mana 540", or both). A prompt
    /// whose only difference is movement says nothing.
    private func speakVitalsDelta(_ vitals: PromptVitals) {
        var parts: [String] = []
        if let hp = vitals.hp, hp != lastSpokenVitals?.hp { parts.append("hp \(hp)") }
        if let mana = vitals.mana, mana != lastSpokenVitals?.mana { parts.append("mana \(mana)") }
        lastSpokenVitals = vitals
        guard !parts.isEmpty else { return }
        speechRequestsContinuation.yield(.speak(text: parts.joined(separator: ", "), interrupt: false))
    }

    internal static var recentDisplayedLimit: Int {
        50
    }

    /// Apply a speech control effect (the TextToSpeech plugin's output +
    /// `proteles.speak`). Returns true when handled.
    internal func applySpeechEffect(_ effect: ScriptEffect) -> Bool {
        switch effect {
        case .speak(let text, let interrupt):
            let spoken = SpeechFilter.normalized(text)
            if !spoken.isEmpty {
                speechRequestsContinuation.yield(.speak(text: spoken, interrupt: interrupt))
            }
        case .stopSpeaking:
            speechRequestsContinuation.yield(.stop)
        case .setSpeechMode(let mode):
            speechMode = mode
            // Turning speech off flushes whatever is still queued —
            // regardless of the path (the `tts off` command already stops;
            // the Settings toggle reaches here via plugin reload and used to
            // leave a minute of backlog babbling on — live report).
            if mode == .off { speechRequestsContinuation.yield(.stop) }
            lastSpokenLineText = nil
            lastSpokenVitals = nil // re-enable re-orients with a fresh baseline
        case .speechConfigChanged:
            speechRequestsContinuation.yield(.reloadConfig)
        case .speakRecentOutput(let count):
            // Most recent last, so playback reads in display order. Skip
            // blank/decoration-only lines — "blank" is useless review.
            let lines = recentDisplayedLines.suffix(max(count, 1))
                .map { SpeechFilter.normalized($0) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else {
                speechRequestsContinuation.yield(.speak(text: "No recent output.", interrupt: true))
                break
            }
            for (index, line) in lines.enumerated() {
                speechRequestsContinuation.yield(.speak(text: line, interrupt: index == 0))
            }
        default:
            return false
        }
        return true
    }

    /// Re-instantiate a native plugin (disable → enable, re-running its
    /// `install()`): the Settings UI calls this after editing a plugin's
    /// hand-editable config file (soundpack.json / speech.json) so the live
    /// plugin re-reads it without an app restart.
    func reloadNativePluginConfig(id: String) async {
        await applyScriptEffects([.reloadPlugin(id: id)])
    }
}
