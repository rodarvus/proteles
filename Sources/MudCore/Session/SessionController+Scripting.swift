import Foundation

/// Applying scripting decisions (triggers/aliases) to the live session.
extension SessionController {
    /// Run a received line through the script engine (if any), then append
    /// it unless a trigger gagged it. Trigger sends/echoes are applied
    /// afterwards so echoes land just below the line that produced them.
    func appendLineThroughScripts(_ line: Line) async {
        guard let scriptEngine else {
            await scrollbackStore.append(line)
            return
        }
        let disposition = await scriptEngine.process(line: line.text)
        if !disposition.gag {
            await scrollbackStore.append(line)
        }
        await applyScriptEffects(disposition.effects)
    }

    /// Apply the effects a script produced: sends go to the MUD, echoes/notes
    /// to the scrollback.
    func applyScriptEffects(_ effects: [ScriptEffect]) async {
        for effect in effects {
            switch effect {
            case .send(let command), .execute(let command), .sendNoEcho(let command):
                try? await sendLine(command)
            case .echo(let text):
                await scrollbackStore.append(Line(id: LineID(0), text: text))
            case .note(let text, let foreground, let background):
                await scrollbackStore.append(Line(
                    id: LineID(0),
                    text: text,
                    runs: Self.noteRuns(text, foreground: foreground, background: background)
                ))
            }
        }
    }

    // MARK: - Script set

    /// Replace the live script set (triggers/aliases/timers) with
    /// `document`'s and restart the timer loop. Called when the active world
    /// changes. No-op without a script engine.
    public func loadScripts(_ document: ScriptDocument) async {
        guard let scriptEngine else { return }
        await scriptEngine.reload(document)
        restartTimerLoop()
    }

    // MARK: - Timers

    /// Add a timer to the script engine and (re)start the driving loop so the
    /// new deadline is picked up. No-op without a script engine.
    @discardableResult
    public func addTimer(_ timer: MudTimer) async throws -> UUID? {
        guard let scriptEngine else { return nil }
        let id = try await scriptEngine.addTimer(timer)
        restartTimerLoop()
        return id
    }

    public func removeTimer(id: UUID) async {
        guard let scriptEngine else { return }
        await scriptEngine.removeTimer(id: id)
        restartTimerLoop()
    }

    public func setTimerEnabled(_ enabled: Bool, id: UUID) async {
        guard let scriptEngine else { return }
        await scriptEngine.setTimerEnabled(enabled, id: id)
        restartTimerLoop()
    }

    /// Atomically replace a timer and restart the loop once. Used by the
    /// editor's live-apply (avoids the remove-then-add reentrancy that can
    /// duplicate registrations).
    public func updateTimer(_ timer: MudTimer) async {
        guard let scriptEngine else { return }
        await scriptEngine.updateTimer(timer)
        restartTimerLoop()
    }

    public func setTimerGroupEnabled(_ enabled: Bool, group: String) async {
        guard let scriptEngine else { return }
        await scriptEngine.setTimerGroupEnabled(enabled, group: group)
        restartTimerLoop()
    }

    /// Cancel any running timer loop and start a fresh one. Called whenever
    /// the timer set changes so a newly-added earlier deadline interrupts an
    /// in-flight sleep. The loop exits on its own when no timers remain.
    func restartTimerLoop() {
        timerTask?.cancel()
        guard let scriptEngine else {
            timerTask = nil
            return
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let deadline = await scriptEngine.nextTimerDeadline() else { return }
                let delay = deadline.timeIntervalSinceNow
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }
                await self?.applyDueTimers()
            }
        }
    }

    /// Fire the timers due at `now` and apply their effects. Factored out so
    /// tests can drive timer firing deterministically without real sleeping.
    func applyDueTimers(at now: Date = Date()) async {
        guard let scriptEngine else { return }
        await applyScriptEffects(scriptEngine.fireDueTimers(at: now))
    }

    static func noteRuns(_ text: String, foreground: String?, background: String?) -> [StyledRun] {
        var style = StyleAttributes.default
        if let foreground, let color = namedColor(foreground) { style.foreground = color }
        if let background, let color = namedColor(background) { style.background = color }
        let length = (text as NSString).length
        guard !style.isDefault, length > 0 else { return [] }
        return [StyledRun(utf16Range: 0..<length, style: style)]
    }

    static func namedColor(_ name: String) -> ANSIColor? {
        let names: [String: NamedColor] = [
            "black": .black, "red": .red, "green": .green, "yellow": .yellow,
            "blue": .blue, "magenta": .magenta, "cyan": .cyan, "white": .white
        ]
        return names[name.lowercased()].map { .named($0) }
    }
}
