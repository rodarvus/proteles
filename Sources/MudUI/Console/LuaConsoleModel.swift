import MudCore
import Observation
import SwiftUI

/// `@Observable` bridge for the Lua Console window: mirrors the session's
/// ``ScriptDiagnosticsStore`` (script errors with plugin attribution + the
/// console transcript) and runs typed code through
/// ``SessionController/runLuaConsoleWindow(_:environment:)`` in the picked
/// plugin environment.
@MainActor
@Observable
public final class LuaConsoleModel {
    public private(set) var lines: [ScriptDiagnostic] = []
    /// Loaded plugin environments for the picker (refreshed on window focus).
    public private(set) var environments: [ScriptEngine.ConsoleEnvironment] = []
    /// The picked environment's plugin id; nil = the user environment.
    public var selectedEnvironment: String?
    public var input = ""
    /// Input history (↑/↓ recall), newest last.
    private var history: [String] = []
    private var historyCursor: Int?

    private let session: SessionController
    private var streamTask: Task<Void, Never>?

    public init(session: SessionController) {
        self.session = session
    }

    /// Begin mirroring the diagnostics store. Idempotent.
    public func start() {
        guard streamTask == nil else { return }
        streamTask = Task { [weak self] in
            guard let self else { return }
            lines = await session.scriptDiagnostics.recent
            for await diagnostic in await session.scriptDiagnostics.subscribe() {
                lines.append(diagnostic)
            }
        }
        refreshEnvironments()
    }

    /// Re-read the loaded plugin list (plugins can load/unload mid-session).
    public func refreshEnvironments() {
        Task { [weak self] in
            guard let self, let engine = session.scriptEngine else { return }
            environments = await engine.consoleEnvironments()
            if let picked = selectedEnvironment, !environments.contains(where: { $0.id == picked }) {
                selectedEnvironment = nil
            }
        }
    }

    /// Run the current input (Return in the field).
    public func submit() {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        input = ""
        history.append(code)
        historyCursor = nil
        let environment = selectedEnvironment
        Task { await session.runLuaConsoleWindow(code, environment: environment) }
    }

    /// ↑ — recall older input.
    public func historyBack() {
        guard !history.isEmpty else { return }
        let cursor = (historyCursor ?? history.count) - 1
        guard cursor >= 0 else { return }
        historyCursor = cursor
        input = history[cursor]
    }

    /// ↓ — toward newer input (past the newest clears the field).
    public func historyForward() {
        guard let cursor = historyCursor else { return }
        if cursor + 1 < history.count {
            historyCursor = cursor + 1
            input = history[cursor + 1]
        } else {
            historyCursor = nil
            input = ""
        }
    }

    /// The console's Clear button.
    public func clear() {
        lines = []
        Task { await session.scriptDiagnostics.clear() }
    }
}
