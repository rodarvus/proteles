import Foundation

/// Ties the scripting layer to a live session: owns a ``LuaRuntime`` and a
/// ``TriggerEngine``, runs incoming lines through the triggers, executes
/// matched scripts with their captures bound, and reports what the host
/// should do (PLAN.md §8.6).
///
/// Pure decision-making — like the engines it composes, it returns
/// ``ScriptEffect``s and a gag decision rather than touching the network or
/// scrollback itself, so it stays testable without a live session. The host
/// (``SessionController``) applies the result.
public actor ScriptEngine {
    /// What to do with a processed line.
    public struct LineDisposition: Sendable, Equatable {
        /// Omit the line from output.
        public var gag: Bool
        /// Effects produced by matched triggers / their scripts, in order.
        public var effects: [ScriptEffect]

        public init(gag: Bool = false, effects: [ScriptEffect] = []) {
            self.gag = gag
            self.effects = effects
        }
    }

    private let runtime: LuaRuntime
    private var triggers = TriggerEngine()

    public init(runtime: LuaRuntime) {
        self.runtime = runtime
    }

    /// Build an engine with a fresh sandboxed runtime.
    public init() throws {
        runtime = try LuaRuntime()
    }

    // MARK: - Triggers

    public func addTrigger(_ trigger: Trigger) throws {
        try triggers.add(trigger)
    }

    public func removeTrigger(id: UUID) {
        triggers.remove(id: id)
    }

    public func setTriggerEnabled(_ enabled: Bool, id: UUID) {
        triggers.setEnabled(enabled, id: id)
    }

    public func setTriggerGroupEnabled(_ enabled: Bool, group: String) {
        triggers.setGroupEnabled(enabled, group: group)
    }

    public var triggerList: [Trigger] {
        triggers.allTriggers
    }

    // MARK: - Processing

    /// Run `line` through the triggers, returning the gag decision and the
    /// effects (trigger sends + script effects, in order). Script errors
    /// surface as red notes rather than aborting.
    public func process(line: String) async -> LineDisposition {
        var disposition = LineDisposition()
        for firing in triggers.process(line) {
            if firing.gag { disposition.gag = true }
            if let send = firing.send, !send.isEmpty {
                disposition.effects.append(.send(send))
            }
            if let script = firing.script {
                await disposition.effects.append(contentsOf: runScript(
                    script,
                    matches: firing.match.captures,
                    named: firing.match.named
                ))
            }
        }
        return disposition
    }

    /// Run an arbitrary script (e.g. from an alias or a command), returning
    /// its effects. Errors surface as a red note.
    @discardableResult
    public func run(_ script: String) async -> [ScriptEffect] {
        await runScript(script, matches: [], named: [:])
    }

    // MARK: - Private

    private func runScript(
        _ script: String,
        matches: [String],
        named: [String: String]
    ) async -> [ScriptEffect] {
        do {
            return try await runtime.runScript(script, matches: matches, named: named)
        } catch {
            return [.note(text: "Script error: \(error)", foreground: "red", background: nil)]
        }
    }
}
