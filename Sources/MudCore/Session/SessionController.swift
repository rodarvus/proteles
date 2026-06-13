import Foundation

/// Owns one MUD session: a ``NetworkConnection`` plus a ``LinePipeline``
/// that turns received bytes into stored ``Line`` records.
///
/// Phase 2 telnet-negotiation policy: `WILL MCCP2` → `DO MCCP2` (accept
/// compression); `WILL <else>` → `DONT`; `DO <anything>` → `WONT`; `WONT` /
/// `DONT` need no reply.
///
/// All byte-parsing lives in ``LinePipeline`` — this actor is the I/O wrapper:
/// it owns the connection, drives the pipeline from the byte stream, dispatches
/// outbound bytes for negotiation replies + user commands, and appends the
/// resulting lines to the scrollback store.
///
/// Concurrency: the controller is an actor; ``scrollbackStore``,
/// ``connection``, ``connectionStates`` are `nonisolated` so the SwiftUI layer
/// can read them without `await`. Inbound bytes are processed in a single
/// long-lived `Task` iterating ``NetworkConnection/bytes``; pipeline state lives
/// on the actor, so only that task mutates it.
///
/// Reconnect: ``connect(to:)`` resets the pipeline, so disconnect + a fresh
/// connect on the same controller behaves like a clean start.
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

    /// Captured continent bigmaps (`{bigmap}…{/bigmap}`), keyed by zone;
    /// rendered by the map panel while overland. Fed by the native
    /// Continent-Bigmap plugin via `.updateBigmap`.
    public nonisolated let bigmapStore: BigmapStore

    /// Script errors (with plugin attribution) + Lua Console transcript,
    /// observed by the Lua Console window. Fed by `.diagnostic` effects and
    /// the console's own evaluations.
    public nonisolated let scriptDiagnostics: ScriptDiagnosticsStore

    /// Durable, controller-lifetime stream of connection-state transitions for
    /// the UI. The underlying ``NetworkConnection`` is *one-shot* (recreated per
    /// ``connect(to:autologin:)``), so its own state stream can't be observed
    /// across reconnects; the controller re-publishes each here as one stream.
    ///
    /// Lifetime note (#58): none of the controller's stream continuations
    /// (this one through `speechRequestsContinuation`) is ever `finish()`ed —
    /// deliberately. The controller is an app-lifetime singleton, so the
    /// streams end with the process and subscribers never need a completion
    /// signal. If sessions ever become per-world objects that come and go, add
    /// a `teardown()` that finishes all of them (and is called from the app's
    /// session-close path) so `for await` consumers unwind instead of leaking.
    public nonisolated let connectionStates: AsyncStream<State>
    /// Internal (not private) so `updateState` in `SessionController+ConnectionState`
    /// can publish onto the stream.
    let connectionStatesContinuation: AsyncStream<State>.Continuation

    /// JSON model snapshots a plugin published (`proteles.publish`, e.g. S&D's
    /// window state) — the UI subscribes and feeds its panel. Newest-only.
    public nonisolated let publishedModels: AsyncStream<String>
    nonisolated let publishedModelsContinuation: AsyncStream<String>.Continuation

    /// Snapshots the native Consider feature published (room-mob list + control
    /// state) — the floating Consider panel subscribes and renders the latest.
    /// Newest-only.
    public nonisolated let publishedConsider: AsyncStream<ConsiderSnapshot>
    nonisolated let publishedConsiderContinuation: AsyncStream<ConsiderSnapshot>.Continuation

    /// Captured in-game help articles (Rich Exits' sibling — see ``HelpParser``);
    /// the Help panel subscribes and renders the latest. Newest-only.
    public nonisolated let helpArticles: AsyncStream<HelpArticle>
    nonisolated let helpArticlesContinuation: AsyncStream<HelpArticle>.Continuation

    /// User notifications (tells/mentions); the app subscribes + posts them.
    public nonisolated let notifications: AsyncStream<ProtelesNotification>
    nonisolated let notificationsContinuation: AsyncStream<ProtelesNotification>.Continuation

    /// Script/plugin button-bar changes (`Button.*` / #15); the app applies them
    /// to the live bar + persists.
    public nonisolated let buttonCommands: AsyncStream<ButtonCommand>
    nonisolated let buttonCommandsContinuation: AsyncStream<ButtonCommand>.Continuation
    /// Sound cues (#10) — `.playSound` effects from the Soundpack plugin, the
    /// compat shim, and the S&D host; the app's cue player subscribes + plays.
    public nonisolated let soundCues: AsyncStream<SoundCue>
    nonisolated let soundCuesContinuation: AsyncStream<SoundCue>.Continuation
    /// Speech requests (#9) — spoken lines + control from the TTS pipeline;
    /// the app's speech controller subscribes (AVSpeechSynthesizer/VoiceOver).
    public nonisolated let speechRequests: AsyncStream<SpeechRequest>
    nonisolated let speechRequestsContinuation: AsyncStream<SpeechRequest>.Continuation
    /// The speech policy (mode, prompt handling, quiet-while-running,
    /// enter-interrupts) — pushed by the TextToSpeech plugin via
    /// `.setSpeechPolicy`. Everything off by default.
    var speechPolicy = SpeechPolicy()
    /// Re-entrancy bound for `.execute` effects. An Execute alias/trigger whose
    /// body re-dispatches into another `.execute` (possibly a cycle, e.g. two
    /// aliases that Execute each other) would otherwise loop forever; MUSHclient
    /// caps this, so we do too.
    var executeDepth = 0
    static let maxExecuteDepth = 20
    /// Whether the character is speedwalking (`char.status.state == 12`),
    /// for the policy's quiet-while-running gate.
    var charIsRunning = false
    /// The last displayed (post-gag) line texts, for `tts last [n]`.
    var recentDisplayedLines: [String] = []
    /// The last line-driven spoken text, for consecutive-repeat suppression
    /// (an unchanged prompt re-sent five times reads once — live report).
    var lastSpokenLineText: String?
    /// The vitals last spoken from a prompt — prompts speak only the
    /// components that changed (and movement never; live-test round 2).
    var lastSpokenVitals: PromptVitals?
    /// The soundpack's master mute, mirrored here so EVERY `.playSound` cue
    /// (S&D's direct calls, shim plugins) honours Settings' "Play event
    /// sounds: off" — not just the soundpack's own events.
    var soundCuesMuted = false
    /// Recent channel messages (display text → channel), so speech can skip
    /// lines from `tts mute`d channels — the text itself stays visible.
    var recentChannelLines: [(text: String, channel: String)] = []
    /// Notifications master toggle (off by default) + which built-in rules fire.
    public var notificationsEnabled = false
    public var notificationMatcher = NotificationMatcher()
    /// Collapses duplicate banners at the publish gate (phase-3).
    var notificationCoalescer = NotificationCoalescer()
    /// Last HP percent seen, for edge-triggered `.hpBelow` rules.
    var lastHPPercent: Int?
    /// Last S&D quest-ready state, for the `.questReady` `false → true` edge.
    var lastQuestReady = false

    /// The current connection (`nil` between sessions); fresh per connect (the
    /// byte stream finishes on disconnect). ``MudConnection`` so tests inject one.
    var connection: (any MudConnection)?

    /// Factory for a fresh connection per session (real by default; tests override).
    let makeConnection: @Sendable () -> any MudConnection
    /// Performs plugins' outbound `async` HTTP requests (injectable for tests).
    let httpClient: any HTTPClient

    /// Mirror of the active connection's state, for synchronous reads.
    /// `internal(set)` (not `private(set)`) so `updateState` in the
    /// `+ConnectionState` extension file can mutate it.
    public internal(set) var state: State = .disconnected

    var pipeline = LinePipeline()
    // Internal (not private): the lifecycle methods that drive these live in
    // SessionController+Lifecycle.swift (the 600-line budget split).
    var processTask: Task<Void, Never>?
    var stateForwardTask: Task<Void, Never>?
    /// Drives the script timers (sleep→fire→loop); restarted when timers change.
    var timerTask: Task<Void, Never>?
    /// Drains the mapper's system-note stream (delayed cexit results) to output.
    var mapperNotesTask: Task<Void, Never>?
    /// Anti-idle (see `SessionController+KeepAlive`): a telnet `IAC NOP` sent
    /// when outbound-quiet for ``keepAliveInterval`` keeps Aardwolf's
    /// command-idle disconnect from firing on a connected-but-quiet session.
    var keepAliveTask: Task<Void, Never>?
    var lastOutboundActivity = Date.distantPast
    let keepAliveInterval: TimeInterval // injectable so tests use a short value
    /// Anti-idle on/off (Connection preference). When false the loop still runs
    /// but sends nothing — so toggling it back on resumes without a reconnect.
    var keepAliveEnabled = true
    var recorder: SessionRecorder?
    /// MUSHclient's `m_bPluginProcessingSend` re-entrancy guard: true while
    /// `OnPluginSend` runs, so a send it issues (dinv's bypass) skips the hook.
    var pluginProcessingSend = false
    /// Vendored dinv's state dir, armed at world-load; loaded lazily on the
    /// first *active* `char.status` (D-32). `dinvLoaded` one-shots that load.
    var pendingDinvStateDirectory: String?
    var dinvLoaded = false
    /// Lines remaining to gag for dinv's background `wish list` probe. dinv runs
    /// `wish list` as a hidden safe-exec probe and *should* gag the output with
    /// its own omit-from-output trigger, but that gag has proven unreliable in the
    /// live multi-plugin environment (the owned `*` rows leak). Since dinv re-sends
    /// `wish list` through its bypass — `pluginProcessingSend` true, distinguishing
    /// it from a user typing `wish list` — the host gags the probe's output itself,
    /// deterministically, until dinv's `DINV wish list fence` marker (or this
    /// safety cap of lines is hit). See ``armWishProbeGagIfNeeded``.
    var wishProbeGagLinesRemaining = 0
    /// Seen an in-game `char.status` (state ≥ 3) this connection? Until then,
    /// `char.status` plugin broadcasts are held (MUSHclient parity — see
    /// `dispatchGMCP`). Reset on connect.
    var seenCharInGame = false
    /// **All** MUSHclient plugin initialisation is held until the character is
    /// in-game — the first `char.status` with state ≥ 3 (after the MOTD), the
    /// same signal dinv has always armed on. Plugins probe the server on init
    /// (`slist`, `cp info`, …) and those commands fail during login/MOTD, so we
    /// don't load them (their `OnPluginInstall`) or fire `OnPluginConnect` until
    /// then. Activation runs once per the in-game signal (or a fallback timer).
    ///
    /// Two guards: ``pluginsLoaded`` is session/world-lifetime (the load +
    /// `OnPluginInstall` happen once; plugins persist across reconnects), while
    /// ``pluginsConnectFired`` is per-connection (`OnPluginConnect` fires on each
    /// reconnect's in-game signal). `armInitialPlugins` resets `pluginsLoaded`
    /// (a fresh world arm → reload); `establish` resets `pluginsConnectFired`.
    var pluginsLoaded = false
    var pluginsConnectFired = false
    /// Pending initial plugin loads, armed at world-load and run on activation:
    /// the enabled library plugin dirs + the per-character data-dir key, and the
    /// bundled leveldb home. (dinv keeps its own arming, `pendingDinvStateDirectory`.)
    var pendingInitialPluginDirectories: [URL] = []
    var pendingInitialPluginCharacter: String?
    var pendingLevelDBDirectory: String?
    /// Fallback that activates plugins if no in-game `char.status` arrives within
    /// a grace window (insurance for a stuck login / a MUD without state 3).
    /// Cancelled on teardown.
    var pluginActivationFallbackTask: Task<Void, Never>?
    /// Plugin id → its code + per-character data directories, for ReloadPlugin
    /// disk re-read and `GetInfo(66)` resolution.
    var loadedPluginPaths: [String: (code: URL, data: URL)] = [:]
    /// Timestamped `.log` beside ``recorder``: local events the wire omits.
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

    /// The live Search-and-Destroy plugin host (set via
    /// ``attachSearchAndDestroy(_:)``); lines, S&D commands, and timers route
    /// through it, and its published model is forwarded to ``publishedModels``.
    public internal(set) var searchAndDestroy: SearchAndDestroyHost?

    /// The lsqlite3 sandbox root: the `~/Documents/Proteles` tree.
    var worldDataDirectory: String?

    /// Latest raw GMCP JSON per package (lowercased key), replayed on re-attach.
    var latestGMCPByPackage: [String: String] = [:]

    /// Subscribers notified when a ``Mapper`` is attached (the map panel
    /// rebinds); subscribe/yield logic lives in the +Scripting extension.
    var mapperAttachmentSubscribers: [UUID: AsyncStream<Mapper>.Continuation] = [:]

    /// True while the server is echoing (`WILL ECHO`, e.g. a password prompt);
    /// local echo of typed input is suppressed until it sends `WONT ECHO`.
    var serverEcho = false

    /// Drop empty MUD lines from output; off by default (`Omit_Blank_Lines`).
    public internal(set) var omitBlankLines = false

    /// Withhold leftover Aardwolf telnet-102 tag lines (`{rname}`/`{coords}`/…)
    /// from the live window; off by default (display-only, post-processing).
    public internal(set) var gagTagLines = false

    /// Rewrite Aardwolf's exits line into clickable direction hyperlinks (Rich
    /// Exits); off by default. When on, sends `tags exits on` after login,
    /// rebuilds the line from ``richExitsCardinals`` + ``richExitsCustomExits``,
    /// and gags the tag-toggle confirmation. See ``RichExits``.
    public internal(set) var richExitsEnabled = false
    /// Whether `tags exits on` has been sent this session (one-shot per connect).
    var sentExitsTag = false
    /// The latest room's cardinal exits (from GMCP `room.info`), cached so the
    /// exits-line rewrite has them ready when the tagged line arrives.
    var richExitsCardinals: [RichExits.Cardinal] = []
    /// The latest room's custom exits (from the mapper graph), cached likewise.
    var richExitsCustomExits: [RichExits.CustomExit] = []

    /// Capture Aardwolf `help <topic>` output into the Help panel (gagged from
    /// the main output) with clickable cross-references; off by default. Tied to
    /// the Help panel's visibility. See ``HelpParser``.
    public internal(set) var helpCaptureEnabled = false
    /// Whether the HELPS tag option (option-102 subneg) was sent this session.
    var sentHelpsTagOption = false
    /// True while buffering lines between `{help}` and `{/help}`.
    var helpCaptureActive = false
    /// Whether the in-progress capture is a `help search` result.
    var helpCaptureIsSearch = false
    /// Accumulated help body lines for the in-progress capture.
    var helpCaptureBuffer: [Line] = []

    /// Drop behaviour; defaults to ``ReconnectPolicy/disabled`` (app sets standard).
    public var reconnectPolicy: ReconnectPolicy

    /// The endpoint / credentials of the most recent ``connect(to:autologin:)``,
    /// retained so an autoreconnect can re-establish the same session.
    var lastEndpoint: NetworkConnection.Endpoint?
    var lastAutologinPlan: AutologinPlan?

    /// The running backoff loop, if any.
    var reconnectTask: Task<Void, Never>?

    /// True between an unexpected drop and either a successful reconnect
    /// or giving up. While set, transient `.disconnected` transitions
    /// from a failing attempt are suppressed so the UI stays on
    /// `.connecting`.
    var isReconnecting = false

    /// Set by ``disconnect()`` so the drop handler knows not to
    /// autoreconnect.
    var userInitiatedDisconnect = false

    /// Set when the user sends a quit command (see ``quitCommands``), so a
    /// following server close is a clean logout, not a drop to autoreconnect
    /// from. Cleared by any other command and on each fresh connect.
    var expectsCleanClose = false

    /// When the most recent quit command was sent. The resume breadcrumb is
    /// dropped only if a close arrives within ``cleanQuitWindow`` of this —
    /// because Aardwolf can **refuse** a quit (combat, confirmation) and leave
    /// you connected. Clearing on the *typed* command lost the session when the
    /// quit was refused and the app was closed before the next heartbeat (#42).
    var quitSentAt: ContinuousClock.Instant?

    /// A server close within this window of a quit command is a clean logout
    /// (Aardwolf closes within ~1–2 s of an accepted `quit`); a later close, or
    /// one with no recent quit, is the session ending while still live.
    static let cleanQuitWindow: Duration = .seconds(10)

    /// Commands that mean "log me out" — a server close right after one is
    /// expected, not a dropped link. Aardwolf's is `quit`.
    public static let quitCommands: Set<String> = ["quit"]

    /// Called when the user **intentionally** ends the session — a `quit`
    /// command or an explicit ``disconnect()`` — but *not* on a drop or an app /
    /// Sparkle-update shutdown (those leave ``userInitiatedDisconnect`` /
    /// ``expectsCleanClose`` false). The app uses it to drop the session-resume
    /// breadcrumb so the next launch doesn't restore a session the user left
    /// (#42). Gating on these flags is what keeps update-resume working.
    var cleanSessionEndHandler: (@Sendable () -> Void)?

    public func setCleanSessionEndHandler(_ handler: @escaping @Sendable () -> Void) {
        cleanSessionEndHandler = handler
    }

    /// Active autologin instruction for the current connection, plus the
    /// phase tracking how far through the prompt sequence we are. `nil`
    /// when autologin is not configured or has completed. (The state type
    /// lives in `SessionController+Autologin.swift`.)
    var autologin: AutologinState?

    /// When true, ``connect(to:)`` opens a fresh recording at
    /// ``autoRecordingURL`` from the first byte (Aardwolf finishes the MCCP2
    /// handshake within ms of TCP-up, so a late start misses it). Mutable.
    public var autoRecord: Bool

    /// Where ``autoRecord`` writes (default: under the app's `recordings/`).
    /// Tests inject a temp-dir builder so they don't litter real recordings.
    public let autoRecordingURL: @Sendable () -> URL?

    /// User-facing session logging (readable text/HTML, distinct from the binary
    /// recording + debug transcript). Off by default. The app supplies a
    /// per-session file URL via ``logFileURL``.
    public var loggingEnabled = false
    public var logFormat: SessionLogFormat = .text
    /// Produces a fresh per-session log file URL at connect (nil = no logging).
    public let logFileURL: @Sendable (SessionLogFormat) -> URL?
    /// The open logger for the current session (nil when not logging).
    var sessionLogger: SessionLogger?
    /// Drains the scrollback stream into ``sessionLogger``.
    var logDrainTask: Task<Void, Never>?

    public init(
        scrollbackStore: ScrollbackStore = ScrollbackStore(),
        gmcpState: GMCPStateStore = GMCPStateStore(),
        chatStore: ChatStore = ChatStore(),
        scriptEngine: ScriptEngine? = nil,
        autoRecord: Bool = false,
        reconnectPolicy: ReconnectPolicy = .disabled,
        keepAliveInterval: TimeInterval = 120,
        autoRecordingURL: @escaping @Sendable () -> URL? = {
            try? SessionRecorder.defaultRecordingURL()
        },
        loggingEnabled: Bool = false,
        logFormat: SessionLogFormat = .text,
        logFileURL: @escaping @Sendable (SessionLogFormat) -> URL? = { _ in nil },
        makeConnection: @escaping @Sendable () -> any MudConnection = { NetworkConnection() },
        httpClient: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.keepAliveInterval = keepAliveInterval
        self.makeConnection = makeConnection
        self.httpClient = httpClient
        self.scrollbackStore = scrollbackStore
        self.gmcpState = gmcpState
        self.chatStore = chatStore
        mapStore = MapStore()
        bigmapStore = BigmapStore(url: BigmapStore.defaultStoreURL())
        scriptDiagnostics = ScriptDiagnosticsStore()
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
        (publishedConsider, publishedConsiderContinuation) =
            AsyncStream<ConsiderSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (helpArticles, helpArticlesContinuation) =
            AsyncStream<HelpArticle>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (notifications, notificationsContinuation) =
            AsyncStream<ProtelesNotification>.makeStream(bufferingPolicy: .bufferingNewest(8))
        (buttonCommands, buttonCommandsContinuation) =
            AsyncStream<ButtonCommand>.makeStream(bufferingPolicy: .bufferingNewest(32))
        (soundCues, soundCuesContinuation) =
            AsyncStream<SoundCue>.makeStream(bufferingPolicy: .bufferingNewest(16))
        (speechRequests, speechRequestsContinuation) =
            AsyncStream<SpeechRequest>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.autoRecord = autoRecord
        self.reconnectPolicy = reconnectPolicy
        self.autoRecordingURL = autoRecordingURL
        self.loggingEnabled = loggingEnabled
        self.logFormat = logFormat
        self.logFileURL = logFileURL
    }

    /// True if MCCP2 has been negotiated and the inbound byte stream is
    /// currently being decompressed.
    public var isCompressionActive: Bool {
        pipeline.isCompressionActive
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
        quitSentAt = nil
        lastEndpoint = endpoint
        lastAutologinPlan = plan

        try await establish(to: endpoint, autologin: plan, surfaceFailureState: true)
    }

    /// Establish a connection and start the inbound pipeline. Shared by
    /// the user-initiated ``connect(to:autologin:)`` and the autoreconnect
    /// loop. When `surfaceFailureState` is true a failure emits
    /// `.disconnected`; the reconnect loop passes false so the UI stays on
    /// `.connecting` between attempts.
    func establish(
        to endpoint: NetworkConnection.Endpoint,
        autologin plan: AutologinPlan?,
        surfaceFailureState: Bool
    ) async throws {
        pipeline.reset()
        autologin = plan.map { AutologinState(plan: $0, phase: .awaitingUsername) }
        pluginsConnectFired = false // per-connection; pluginsLoaded persists across reconnects
        sentExitsTag = false
        richExitsCardinals = []
        richExitsCustomExits = []
        sentHelpsTagOption = false
        helpCaptureActive = false
        helpCaptureBuffer = []
        recentDisplayedLines = [] // a fresh connection's `tts last` never replays the old session
        lastSpokenLineText = nil
        lastSpokenVitals = nil
        await gmcpState.reset()
        latestGMCPByPackage.removeAll()
        // chatStore deliberately NOT reset: chat history is persistent (#57),
        // so like scrollback it spans reconnects — wiping it here would also
        // discard a freshly-restored resume backlog on the first connect.
        await mapStore.reset()

        let conn = makeConnection()
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
        startSessionLogIfEnabled()

        startProcessingLoop(on: conn)
        restartTimerLoop()
    }

    /// Send a user-typed command (aliases when a script engine is present, else
    /// verbatim; `\r\n` appended). Tracks `quit` so the ensuing server close is
    /// a clean logout, not a dropped link that would autoreconnect.
    public func send(_ command: String) async throws {
        // Typed input cuts stale speech (community canon, `tts enter` toggles)
        // — including the bare "press Enter to shut it up" reflex.
        interruptSpeechForTypedCommand()
        // A bare Enter means nothing at the login prompts but restarts
        // Aardwolf's name flow and strands autologin (the 2026-06-11 resume
        // incident: stray empties dead-ended the login). Drop empties while
        // autologin is mid-flight; the MOTD's "Press Return" comes after.
        if autologin != nil, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        expectsCleanClose = Self.quitCommands.contains(
            command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        // Don't drop the resume breadcrumb here — Aardwolf can REFUSE a quit
        // (combat, confirmation) and leave you connected. We only treat it as a
        // clean end if the server actually closes soon after (see
        // ``handleByteStreamEnded`` + ``cleanQuitWindow``). Record when the quit
        // was sent; a non-quit command clears it (you're plainly still playing).
        quitSentAt = expectsCleanClose ? .now : nil
        // Echo typed input (dimmed) so it's visible — e.g. while writing a note.
        // Suppressed when the server echoes (passwords) and for the bare
        // prompt-refresh Enter; the transcript tap is gated the same way.
        if !serverEcho, !command.isEmpty {
            await scrollbackStore.append(Self.inputEchoLine(command))
            logTranscript(.input, command)
        }
        try await dispatchCommand(command)
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
        lastOutboundActivity = Date()
        // Time the actual socket write. The `.send` transcript line is logged
        // before this await (it records intent); if the write itself stalls,
        // that's an outbound-path delay we otherwise can't see in a recording
        // (which only tees inbound). Surface a slow write so a "command response
        // was late" report can be pinned to our side vs the server/network.
        let writeStart = Date()
        do {
            try await connection.send(bytes)
            let elapsed = Date().timeIntervalSince(writeStart)
            if elapsed > 0.25 {
                logTranscript(.note, "[slow-send] \(bytes.count)B socket write took \(Int(elapsed * 1000))ms")
            }
        } catch let error as NetworkConnection.ConnectionError {
            switch error {
            case .notConnected:
                throw SessionError.notConnected
            default:
                throw SessionError.sendFailed(error.localizedDescription)
            }
        }
    }
}
