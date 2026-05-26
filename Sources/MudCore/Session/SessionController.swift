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

    /// Latest captured ASCII map (`<MAPSTART>…<MAPEND>`); observed by the
    /// Map window. Fed by the native ASCII-map plugin via `.updateMap`.
    public nonisolated let mapStore: MapStore

    /// Durable, controller-lifetime stream of connection-state
    /// transitions for the UI to observe.
    ///
    /// The underlying ``NetworkConnection`` is a *one-shot* object —
    /// recreated per ``connect(to:autologin:)``, so its own state stream can't
    /// be observed across reconnects; the controller re-publishes each
    /// connection's transitions here as one stable app-session stream.
    public nonisolated let connectionStates: AsyncStream<State>
    private let connectionStatesContinuation: AsyncStream<State>.Continuation

    /// JSON model snapshots a plugin published (`proteles.publish`, e.g. S&D's
    /// window state) — the UI subscribes and feeds its panel. Newest-only.
    public nonisolated let publishedModels: AsyncStream<String>
    nonisolated let publishedModelsContinuation: AsyncStream<String>.Continuation

    /// The current network connection, or `nil` between sessions. Fresh per
    /// ``connect(to:autologin:)`` — ``NetworkConnection`` finishes its byte
    /// stream on disconnect and can't be reused.
    var connection: NetworkConnection?

    /// Mirror of the active connection's state, for synchronous reads.
    public private(set) var state: State = .disconnected

    var pipeline = LinePipeline()
    private var processTask: Task<Void, Never>?
    private var stateForwardTask: Task<Void, Never>?
    /// Drives the script timers (sleep→fire→loop); restarted when timers change.
    var timerTask: Task<Void, Never>?
    /// Drains the mapper's system-note stream (delayed cexit results) to output.
    var mapperNotesTask: Task<Void, Never>?
    var recorder: SessionRecorder?
    /// Re-entrancy guard for the `OnPluginSend` hook (a plugin may re-send,
    /// re-entering the hook); caps pathological loops.
    var pluginSendDepth = 0
    /// Vendored dinv's state dir, armed at world-load; loaded lazily on the
    /// first *active* `char.status` (D-32). `dinvLoaded` one-shots that load.
    var pendingDinvStateDirectory: String?
    var dinvLoaded = false
    /// Timestamped debug transcript paired with ``recorder`` (`.log` beside the
    /// `.jsonl`): logs local events the wire capture omits (input/sends/notes/GMCP).
    var transcript: SessionTranscript?
    /// Per-world persistence for scoped script/plugin variables (write-through).
    var variableStore: VariableStore?
    /// Per-world persistence for native-plugin state (e.g. `#sub`/`#gag`
    /// rules) and enabled flags. Set via ``attachNativePluginStore(_:)`` when
    /// a world loads; written through when a plugin's state changes.
    var nativePluginStore: NativePluginStore?

    /// The live map. Set via ``attachMapper(_:)`` when a world loads; fed
    /// `room.info`/`room.area`/`room.sectors` from the GMCP stream.
    public internal(set) var mapper: Mapper?

    /// The live Search-and-Destroy plugin host. Set via
    /// ``attachSearchAndDestroy(_:)`` when a world loads; incoming lines,
    /// typed S&D commands, and timers are routed through it, and the model it
    /// publishes is forwarded to ``publishedModels``.
    public internal(set) var searchAndDestroy: SearchAndDestroyHost?

    /// Per-profile world-data dir (`GetInfo(66)` + lsqlite3 sandbox root).
    var worldDataDirectory: String?

    /// Subscribers notified when a ``Mapper`` is attached (the map panel
    /// rebinds); subscribe/yield logic lives in the +Scripting extension.
    var mapperAttachmentSubscribers: [UUID: AsyncStream<Mapper>.Continuation] = [:]

    /// True while the server is echoing (`WILL ECHO`, e.g. a password prompt);
    /// local echo of typed input is suppressed until it sends `WONT ECHO`.
    var serverEcho = false

    /// Drop empty MUD lines from output; off by default (`Omit_Blank_Lines`).
    public internal(set) var omitBlankLines = false

    /// Drop behaviour; defaults to ``ReconnectPolicy/disabled`` (app sets standard).
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
    var gmcpHandshakeSent = false

    /// Active autologin instruction for the current connection, plus the
    /// phase tracking how far through the prompt sequence we are. `nil`
    /// when autologin is not configured or has completed.
    var autologin: AutologinState?

    struct AutologinState {
        var plan: AutologinPlan
        var phase: Phase

        enum Phase {
            case awaitingUsername
            case awaitingPassword
            case done
        }
    }

    /// When true, ``connect(to:)`` opens a fresh recording at
    /// ``autoRecordingURL`` so the capture includes every byte from the first
    /// one — crucial for replayable recordings, because Aardwolf completes the
    /// MCCP2 handshake within milliseconds of TCP-up. Mutable at runtime.
    public var autoRecord: Bool

    /// Where ``autoRecord`` writes. Defaults to
    /// ``SessionRecorder/defaultRecordingURL(now:fileManager:)`` (under
    /// `~/Library/Application Support/com.proteles.ProtelesApp/recordings/`).
    /// Tests inject a temp-dir builder so they don't litter real recordings.
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
        mapStore = MapStore()
        self.scriptEngine = scriptEngine
        let (stream, continuation) = AsyncStream<State>.makeStream(
            bufferingPolicy: .unbounded
        )
        connectionStates = stream
        connectionStatesContinuation = continuation
        continuation.yield(.disconnected)
        let (models, modelsContinuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        publishedModels = models
        publishedModelsContinuation = modelsContinuation
        self.autoRecord = autoRecord
        self.reconnectPolicy = reconnectPolicy
        self.autoRecordingURL = autoRecordingURL
    }

    /// True if MCCP2 has been negotiated and the inbound byte stream is
    /// currently being decompressed.
    public var isCompressionActive: Bool {
        pipeline.isCompressionActive
    }

    /// True while a recording is being written. Surfaced for menu state
    /// tracking; the view layer observes ``recordingStarted`` instead of polling.
    public var isRecording: Bool {
        recorder != nil
    }

    /// Start recording every inbound wire chunk to `url` (and open the paired
    /// debug transcript). Any prior recording is closed first. Recordings
    /// capture raw wire bytes (pre-decompression, pre-telnet-parse), so a
    /// replay exercises the full protocol stack — including MCCP2. Best-effort:
    /// write failures silence further recording rather than tear down the
    /// session.
    public func startRecording(to url: URL) throws {
        recorder?.close()
        transcript?.close()
        recorder = try SessionRecorder(url: url)
        transcript = try? SessionTranscript(url: SessionTranscript.url(pairedWith: url))
    }

    /// Stop the current recording. Idempotent.
    public func stopRecording() {
        recorder?.close()
        recorder = nil
        transcript?.close()
        transcript = nil
    }

    /// Open a connection and start the inbound processing pipeline. If
    /// ``autoRecord`` is true and no manual recording is in progress, opens a
    /// fresh recording at ``autoRecordingURL`` so the capture starts from byte
    /// one (covering the telnet + MCCP2 handshake — what makes it replayable).
    public func connect(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan? = nil
    ) async throws {
        guard connection == nil else {
            throw SessionError.alreadyConnected
        }
        // A fresh user-initiated connect cancels in-flight backoff + latches.
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
        await mapStore.reset()

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
            transcript = try? SessionTranscript(url: SessionTranscript.url(pairedWith: url))
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
        // Locally echo what the user typed (dimmed), so input is visible —
        // notably while writing a note. Suppressed when the server is echoing
        // (password prompts) and for the bare prompt-refresh Enter. The
        // transcript tap is gated the same way so a typed password isn't logged.
        if !serverEcho, !command.isEmpty {
            await scrollbackStore.append(Self.inputEchoLine(command))
            logTranscript(.input, command)
        }
        try await dispatchCommand(command)
    }

    /// Route a command through the in-app pipeline (native `mapper …` → S&D
    /// aliases → user aliases → MUD), without the user-input echo. Used by
    /// typed input (after echo) and by a plugin's `Execute`, which re-parses
    /// the command as if typed — MUSHclient's `Execute` semantics. This is
    /// what makes S&D's navigation (`do_mapper_goto` → `Execute("mapper goto
    /// <id>")`) reach the native mapper instead of being sent raw to the MUD.
    func dispatchCommand(_ command: String) async throws {
        // Command stacking (Aardwolf/MUSHclient): split on `;` (`;;` = literal
        // `;`), dispatching each command. A lone empty piece is a bare-Enter
        // prompt nudge and is preserved.
        let pieces = CommandStack.split(command)
        for piece in pieces {
            if piece.isEmpty, pieces.count > 1 { continue }
            try await dispatchSingleCommand(piece)
        }
    }

    /// Route one (already unstacked) command through the in-app pipeline.
    private func dispatchSingleCommand(_ command: String) async throws {
        // Native `mapper …` commands are handled in-app, not sent to the MUD.
        if command.split(separator: " ").first?.lowercased() == "mapper", let mapper {
            await applyScriptEffects(mapper.handleCommand(command))
            return
        }
        // Search-and-Destroy's own commands (xcp/nx/qs/…) are intercepted by
        // its aliases before the normal path.
        if await handleSearchAndDestroyCommand(command) {
            return
        }
        if let scriptEngine {
            await applyScriptEffects(scriptEngine.expandInput(command))
            await persistVariablesIfDirty()
        } else {
            try await sendLine(command)
        }
    }

    /// Send a single line to the MUD (raw text + `\r\n`), bypassing alias
    /// expansion. Used for internal sends (autologin, applied effects).
    /// `redactInTranscript` hides secrets (the autologin password) from the
    /// debug transcript while still sending them on the wire.
    func sendLine(_ text: String, redactInTranscript: Bool = false) async throws {
        logTranscript(.send, redactInTranscript ? "<redacted>" : text)
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
        syncTimerLoop(to: newState)
        // Keep S&D's `IsConnected()` in sync (gates its init bootstrap). S&D
        // auto-detects an already-running campaign itself (its init hook runs
        // do_cp_info once initialised); the panel's gear menu offers a manual
        // re-check as a fallback.
        if let searchAndDestroy {
            Task { await searchAndDestroy.setConnected(newState == .connected) }
        }
        // Keep scripts' `proteles.isConnected` in sync and drive plugin
        // connect/disconnect lifecycle callbacks.
        if let scriptEngine {
            Task { [weak self] in
                await scriptEngine.setConnected(newState == .connected)
                var effects: [ScriptEffect] = switch newState {
                case .connected: await scriptEngine.connectPlugins()
                case .disconnected: await scriptEngine.disconnectPlugins()
                default: []
                }
                if newState == .connected {
                    await effects.append(contentsOf: scriptEngine.connectNativePlugins())
                }
                if !effects.isEmpty { await self?.applyScriptEffects(effects) }
                await self?.persistVariablesIfDirty()
            }
        }
    }

    /// Drive the timer loop with the connection: start it on connect (so a
    /// reconnect re-arms timers), stop it on disconnect so recurring timers
    /// (e.g. S&D's 0.5s tim_init_plugin bootstrap) don't spin on a dead
    /// session. A remote drop also cancels the loop via teardownSession; this
    /// covers the reconnect re-arm.
    private func syncTimerLoop(to newState: State) {
        switch newState {
        case .connected: restartTimerLoop()
        case .disconnected: timerTask?.cancel(); timerTask = nil
        default: break
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
        // Stop the timer loop so recurring plugin/S&D timers don't keep firing
        // on a dropped session (re-armed by updateState on the next connect).
        timerTask?.cancel()
        timerTask = nil
        recorder?.close()
        recorder = nil
        transcript?.close()
        transcript = nil
        autologin = nil
        connection = nil
        dinvLoaded = false // reloads on the next active char.status (e.g. reconnect)
    }
}
