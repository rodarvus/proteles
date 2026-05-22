import Foundation

/// Owns one MUD session: a ``NetworkConnection`` plus a ``LinePipeline``
/// that turns received bytes into stored ``Line`` records.
///
/// Phase 2 telnet-negotiation policy:
///   - `WILL MCCP2`  → `DO MCCP2`  (accept compression).
///   - `WILL <anything else>` → `DONT <option>`.
///   - `DO  <anything>`        → `WONT <option>`.
///   - `WONT` / `DONT` need no reply.
///
/// All actual byte-parsing logic lives in ``LinePipeline`` — this actor
/// is the I/O wrapper: it owns the connection, drives the pipeline
/// from the byte stream, dispatches outbound bytes for negotiation
/// replies and user commands, and appends the resulting lines to the
/// scrollback store.
///
/// Concurrency model:
///
///   - The controller is an actor.
///   - ``scrollbackStore``, ``connection``, ``connectionStates`` are
///     `nonisolated` so the SwiftUI view layer can read / observe them
///     without `await`.
///   - Inbound bytes are processed inside a single long-lived `Task`
///     that iterates ``NetworkConnection/bytes``. Pipeline state lives
///     on the actor and is therefore only mutated by that task.
///
/// Reconnect: ``connect(to:)`` resets the pipeline, so a `disconnect`
/// followed by a fresh `connect` on the same controller behaves like
/// a clean start.
public actor SessionController {
    public typealias State = NetworkConnection.State

    /// Errors surfaced to callers.
    public enum SessionError: Error, Sendable, Equatable {
        case alreadyConnected
        case notConnected
        case sendFailed(String)
    }

    /// Backing scrollback. Populated by the inbound pipeline; exposed to
    /// the view layer.
    public nonisolated let scrollbackStore: ScrollbackStore

    /// Decoded Aardwolf GMCP state (vitals, status, …). Fed by the inbound
    /// pipeline; observed by the status bar.
    public nonisolated let gmcpState: GMCPStateStore

    /// Optional scripting engine. When present, every received line is run
    /// through its triggers; resulting sends go to the MUD, echoes/notes to
    /// the scrollback, and gagged lines are dropped.
    public nonisolated let scriptEngine: ScriptEngine?

    /// Captured `comm.channel` chat lines. Fed by the inbound pipeline;
    /// observed by the chat-capture window.
    public nonisolated let chatStore: ChatStore

    /// Durable, controller-lifetime stream of connection-state
    /// transitions for the UI to observe.
    ///
    /// The underlying ``NetworkConnection`` is a *one-shot* object —
    /// recreated for every ``connect(to:autologin:)`` — so its own state
    /// stream can't be observed across reconnects. The controller
    /// re-publishes each connection's transitions here, giving the view
    /// layer one stable stream for the whole app session.
    public nonisolated let connectionStates: AsyncStream<State>
    private let connectionStatesContinuation: AsyncStream<State>.Continuation

    /// The current network connection, or `nil` between sessions. A fresh
    /// instance is created per ``connect(to:autologin:)`` because
    /// ``NetworkConnection`` finishes its byte stream on disconnect and
    /// can't be reused.
    private var connection: NetworkConnection?

    /// Mirror of the active connection's state, kept so callers (and the
    /// reconnect guard) can read it synchronously.
    public private(set) var state: State = .disconnected

    private var pipeline = LinePipeline()
    private var processTask: Task<Void, Never>?
    private var stateForwardTask: Task<Void, Never>?
    /// Drives the script engine's timers: sleeps until the next deadline,
    /// fires the due timers, then loops. Restarted whenever timers change.
    var timerTask: Task<Void, Never>?
    private var recorder: SessionRecorder?

    /// Behaviour on an unexpected drop. Defaults to ``ReconnectPolicy/disabled``
    /// so library/test callers opt in explicitly; the app sets
    /// ``ReconnectPolicy/standard``.
    public var reconnectPolicy: ReconnectPolicy

    /// The endpoint / credentials of the most recent ``connect(to:autologin:)``,
    /// retained so an autoreconnect can re-establish the same session.
    private var lastEndpoint: NetworkConnection.Endpoint?
    private var lastAutologinPlan: AutologinPlan?

    /// The running backoff loop, if any.
    private var reconnectTask: Task<Void, Never>?

    /// True between an unexpected drop and either a successful reconnect
    /// or giving up. While set, transient `.disconnected` transitions
    /// from a failing attempt are suppressed so the UI stays on
    /// `.connecting`.
    private var isReconnecting = false

    /// Set by ``disconnect()`` so the drop handler knows not to
    /// autoreconnect.
    private var userInitiatedDisconnect = false

    /// Set when the user sends a quit command (see ``quitCommands``), so a
    /// server-initiated close that follows is treated as a clean logout —
    /// not an unexpected drop to autoreconnect from. Cleared by any other
    /// command (e.g. if the quit needed confirming and the user kept
    /// playing) and on each fresh connect.
    private var expectsCleanClose = false

    /// Commands that mean "log me out" — a server close right after one is
    /// expected, not a dropped link. Aardwolf's is `quit`.
    public static let quitCommands: Set<String> = ["quit"]

    /// Whether the GMCP handshake has been sent for the current
    /// connection (sent once, when the server enables GMCP).
    private var gmcpHandshakeSent = false

    /// Active autologin instruction for the current connection, plus the
    /// phase tracking how far through the prompt sequence we are. `nil`
    /// when autologin is not configured or has completed.
    private var autologin: AutologinState?

    private struct AutologinState {
        var plan: AutologinPlan
        var phase: Phase

        enum Phase {
            case awaitingUsername
            case awaitingPassword
            case done
        }
    }

    /// When true, ``connect(to:)`` opens a fresh recording at
    /// ``autoRecordingURL`` so the capture includes every byte from
    /// the first one — crucial for replayable recordings, because
    /// Aardwolf completes the MCCP2 handshake within milliseconds of
    /// TCP-up. The flag is mutable at runtime so a Debug menu can
    /// expose it in a later iteration.
    public var autoRecord: Bool

    /// Where ``autoRecord`` writes. Defaults to
    /// ``SessionRecorder/defaultRecordingURL(now:fileManager:)`` (which
    /// places files under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/recordings/`).
    /// Tests inject a temp-dir builder so they don't litter the
    /// developer's real recordings directory.
    public let autoRecordingURL: @Sendable () -> URL?

    public init(
        scrollbackStore: ScrollbackStore = ScrollbackStore(),
        gmcpState: GMCPStateStore = GMCPStateStore(),
        chatStore: ChatStore = ChatStore(),
        scriptEngine: ScriptEngine? = nil,
        autoRecord: Bool = false,
        reconnectPolicy: ReconnectPolicy = .disabled,
        autoRecordingURL: @escaping @Sendable () -> URL? = {
            try? SessionRecorder.defaultRecordingURL()
        }
    ) {
        self.scrollbackStore = scrollbackStore
        self.gmcpState = gmcpState
        self.chatStore = chatStore
        self.scriptEngine = scriptEngine
        let (stream, continuation) = AsyncStream<State>.makeStream(
            bufferingPolicy: .unbounded
        )
        connectionStates = stream
        connectionStatesContinuation = continuation
        continuation.yield(.disconnected)
        self.autoRecord = autoRecord
        self.reconnectPolicy = reconnectPolicy
        self.autoRecordingURL = autoRecordingURL
    }

    /// True if MCCP2 has been negotiated and the inbound byte stream is
    /// currently being decompressed.
    public var isCompressionActive: Bool {
        pipeline.isCompressionActive
    }

    /// True while a recording is being written. Surfaced for menu
    /// state tracking; the view layer observes this via
    /// ``recordingStarted`` notifications instead of polling.
    public var isRecording: Bool {
        recorder != nil
    }

    /// Start recording every inbound wire chunk to `url`. Any prior
    /// recording is closed cleanly first. Recordings capture the raw
    /// wire bytes (pre-decompression, pre-telnet-parse), so a replay
    /// exercises the full protocol stack — including MCCP2.
    ///
    /// The recorder is **best-effort** — write failures silence
    /// further recording rather than tear the session down, matching
    /// the rest of MudCore's bias toward keeping the user's session
    /// alive in the face of secondary failures.
    public func startRecording(to url: URL) throws {
        recorder?.close()
        recorder = try SessionRecorder(url: url)
    }

    /// Stop the current recording. Idempotent.
    public func stopRecording() {
        recorder?.close()
        recorder = nil
    }

    /// Open a connection and start the inbound processing pipeline.
    /// If ``autoRecord`` is true and no manual recording is already in
    /// progress, opens a fresh recording at ``autoRecordingURL`` so
    /// the capture starts from byte one (covers the telnet + MCCP2
    /// handshake, which is what makes the recording replayable).
    public func connect(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan? = nil
    ) async throws {
        guard connection == nil else {
            throw SessionError.alreadyConnected
        }
        // A fresh user-initiated connect cancels any in-flight backoff and
        // clears the "user disconnected" latch.
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        userInitiatedDisconnect = false
        expectsCleanClose = false
        lastEndpoint = endpoint
        lastAutologinPlan = plan

        try await establish(to: endpoint, autologin: plan, surfaceFailureState: true)
    }

    /// Establish a connection and start the inbound pipeline. Shared by
    /// the user-initiated ``connect(to:autologin:)`` and the autoreconnect
    /// loop. When `surfaceFailureState` is true a failure emits
    /// `.disconnected`; the reconnect loop passes false so the UI stays on
    /// `.connecting` between attempts.
    private func establish(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan?,
        surfaceFailureState: Bool
    ) async throws {
        pipeline.reset()
        autologin = plan.map { AutologinState(plan: $0, phase: .awaitingUsername) }
        gmcpHandshakeSent = false
        await gmcpState.reset()
        await chatStore.reset()

        let conn = NetworkConnection()
        connection = conn
        // Re-publish this connection's state transitions onto the durable
        // stream so the UI keeps observing across reconnects.
        stateForwardTask = Task { [weak self] in
            for await newState in conn.states {
                await self?.forwardConnectionState(newState)
            }
        }

        do {
            try await conn.connect(to: endpoint)
        } catch {
            teardownSession()
            if surfaceFailureState { updateState(.disconnected) }
            throw error
        }

        if autoRecord, recorder == nil, let url = autoRecordingURL() {
            recorder = try? SessionRecorder(url: url)
        }

        startProcessingLoop(on: conn)
        restartTimerLoop()
    }

    /// Close the connection. Idempotent. A user-initiated disconnect — it
    /// suppresses autoreconnect.
    public func disconnect() async {
        userInitiatedDisconnect = true
        isReconnecting = false
        reconnectTask?.cancel()
        reconnectTask = nil
        timerTask?.cancel()
        timerTask = nil

        if let conn = connection {
            teardownSession()
            await conn.disconnect()
            await flushOnDisconnect()
        }
        updateState(.disconnected)
    }

    /// Send a user-typed command. When a script engine is present the line
    /// is first run through its aliases (so a matched alias rewrites it);
    /// otherwise it goes to the MUD verbatim. Either way `\r\n` is appended.
    ///
    /// Tracks quit commands so the server-initiated close that follows a
    /// `quit` is treated as a clean logout rather than a dropped link —
    /// otherwise autoreconnect would immediately drag the user back in.
    public func send(_ command: String) async throws {
        expectsCleanClose = Self.quitCommands.contains(
            command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        if let scriptEngine {
            await applyScriptEffects(scriptEngine.expandInput(command))
        } else {
            try await sendLine(command)
        }
    }

    /// Send a single line to the MUD (raw text + `\r\n`), bypassing alias
    /// expansion. Used for internal sends (autologin, applied effects).
    func sendLine(_ text: String) async throws {
        try await sendRaw(Array((text + "\r\n").utf8))
    }

    /// Send raw bytes verbatim (no line terminator added).
    public func sendRaw(_ bytes: [UInt8]) async throws {
        guard let connection else { throw SessionError.notConnected }
        do {
            try await connection.send(bytes)
        } catch let error as NetworkConnection.ConnectionError {
            switch error {
            case .notConnected:
                throw SessionError.notConnected
            default:
                throw SessionError.sendFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private func startProcessingLoop(on conn: NetworkConnection) {
        processTask?.cancel()
        let bytesStream = conn.bytes
        processTask = Task { [weak self] in
            for await chunk in bytesStream {
                await self?.processChunk(chunk)
            }
            // The byte stream finishing means the peer closed (or the
            // connection failed): wind the session down. A local
            // ``disconnect()`` cancels this task first, so this path only
            // fires for remote-initiated closes.
            await self?.handleByteStreamEnded()
        }
    }

    /// React to the inbound byte stream ending on its own — a
    /// remote-initiated close. Flushes any trailing line and tears the
    /// session down, then either begins autoreconnect (if the policy is
    /// enabled and this was neither a user disconnect nor a clean quit) or
    /// surfaces `.disconnected`.
    private func handleByteStreamEnded() async {
        guard connection != nil else { return }
        await flushOnDisconnect()
        teardownSession()

        let shouldReconnect = reconnectPolicy.isEnabled
            && !userInitiatedDisconnect
            && !expectsCleanClose
            && lastEndpoint != nil
        if shouldReconnect {
            beginReconnect()
        } else {
            updateState(.disconnected)
        }
    }

    /// Forward an underlying-connection transition onto the durable
    /// stream, suppressing the transient `.disconnected` of a failed
    /// attempt while a reconnect cycle is in progress.
    private func forwardConnectionState(_ newState: State) {
        if isReconnecting, newState == .disconnected { return }
        updateState(newState)
    }

    /// Drive the exponential-backoff reconnect loop. Surfaces
    /// `.connecting` for the duration; ends by either re-establishing the
    /// session or, once ``ReconnectPolicy/maxAttempts`` is hit, emitting
    /// `.disconnected`.
    private func beginReconnect() {
        guard let endpoint = lastEndpoint else {
            updateState(.disconnected)
            return
        }
        isReconnecting = true
        updateState(.connecting)

        let policy = reconnectPolicy
        let plan = lastAutologinPlan
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            var attempt = 1
            while !Task.isCancelled {
                if policy.maxAttempts > 0, attempt > policy.maxAttempts {
                    await self?.reconnectExhausted()
                    return
                }
                try? await Task.sleep(for: policy.delay(forAttempt: attempt))
                if Task.isCancelled { return }
                let reconnected = await self?.reconnectAttempt(
                    to: endpoint,
                    autologin: plan
                ) ?? false
                if reconnected { return }
                attempt += 1
            }
        }
    }

    /// One reconnection attempt. Returns true on success (loop stops) or
    /// if the user disconnected in the meantime (loop should bail).
    private func reconnectAttempt(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan?
    ) async -> Bool {
        guard !userInitiatedDisconnect else { return true }
        do {
            try await establish(to: endpoint, autologin: plan, surfaceFailureState: false)
            isReconnecting = false
            return true
        } catch {
            // Stay visibly "connecting" for the next attempt.
            updateState(.connecting)
            return false
        }
    }

    private func reconnectExhausted() {
        isReconnecting = false
        updateState(.disconnected)
    }

    /// Update the mirrored state and republish it. Deduplicates so the
    /// durable stream never emits the same state twice in a row.
    private func updateState(_ newState: State) {
        guard newState != state else { return }
        state = newState
        connectionStatesContinuation.yield(newState)
        // Keep scripts' `proteles.isConnected` in sync.
        if let scriptEngine {
            let connected = newState == .connected
            Task { await scriptEngine.setConnected(connected) }
        }
    }

    /// Cancel the per-session tasks and drop the connection so the next
    /// ``connect(to:autologin:)`` starts clean. Idempotent. Does *not*
    /// emit a state transition — callers do that explicitly.
    private func teardownSession() {
        processTask?.cancel()
        processTask = nil
        stateForwardTask?.cancel()
        stateForwardTask = nil
        recorder?.close()
        recorder = nil
        autologin = nil
        connection = nil
    }

    private func processChunk(_ wireBytes: [UInt8]) async {
        // Tee to the recorder before doing any parser work — we want
        // the *wire* bytes on disk so a replay re-runs the full
        // protocol stack (MCCP2 included) deterministically.
        try? recorder?.record(wireBytes)

        let output: LinePipeline.Output
        do {
            output = try pipeline.consume(wireBytes)
        } catch {
            // Corrupt MCCP stream — drop the session. Future phases
            // will surface a user-visible error rather than bail
            // silently.
            await disconnect()
            return
        }

        // Negotiation replies go out before line appends so the server
        // sees them promptly.
        for response in output.responses {
            try? await connection?.send(response)
        }
        for line in output.lines {
            await appendLineThroughScripts(line)
        }

        // The server enabled GMCP — send our handshake once so it starts
        // streaming Char/Comm/Room modules.
        if output.enabledGMCP {
            await sendGMCPHandshake()
        }
        for message in output.gmcp {
            await gmcpState.apply(message)
            await chatStore.ingest(message)
            if let scriptEngine {
                await applyScriptEffects(
                    scriptEngine.applyGMCP(package: message.package, json: message.json)
                )
            }
        }

        await advanceAutologin(newLines: output.lines)
    }

    /// Send the Aardwolf GMCP handshake (Core.Hello, Core.Supports.Set,
    /// then the config/request batch). Sent at most once per connection.
    private func sendGMCPHandshake() async {
        guard !gmcpHandshakeSent else { return }
        gmcpHandshakeSent = true
        for packet in GMCPMessage.aardwolfHandshake(clientVersion: MudCore.version) {
            try? await connection?.send(packet)
        }
    }

    /// Drive the prompt-driven (Diku-style) autologin sequence. Called
    /// after each processed chunk with the lines it produced.
    ///
    /// Prompts arrive without a trailing newline, so they sit in
    /// ``LinePipeline/pendingLineText`` rather than appearing as a
    /// ``Line``. We scan both the freshly emitted lines (in case a world
    /// terminates its prompts) and the pending buffer.
    private func advanceAutologin(newLines: [Line]) async {
        guard var state = autologin else { return }

        switch state.phase {
        case .awaitingUsername:
            guard sees(state.plan.usernamePrompt, in: newLines) else { return }
            // Credentials bypass alias expansion and quit detection.
            try? await sendLine(state.plan.username)
            // Skip the password wait entirely when there's nothing to
            // send; some characters have no password.
            state.phase = state.plan.password.isEmpty ? .done : .awaitingPassword
        case .awaitingPassword:
            guard sees(state.plan.passwordPrompt, in: newLines) else { return }
            try? await sendLine(state.plan.password)
            state.phase = .done
        case .done:
            break
        }

        autologin = state.phase == .done ? nil : state
    }

    /// True if `needle` appears in any of `lines` or in the pipeline's
    /// current un-terminated pending text.
    private func sees(_ needle: String, in lines: [Line]) -> Bool {
        guard !needle.isEmpty else { return false }
        if pipeline.pendingLineText.contains(needle) { return true }
        return lines.contains { $0.text.contains(needle) }
    }

    private func flushOnDisconnect() async {
        let trailing = pipeline.flush()
        for line in trailing {
            await scrollbackStore.append(line)
        }
    }
}
