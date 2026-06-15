import Foundation

/// Synchronous, value-type pipeline that turns raw wire bytes into
/// ``Line`` records.
///
/// Composes the four parsers in the order they appear on the inbound
/// path:
///
///     wire bytes
///       → (optional) Inflater     // MCCP2 (ARCHITECTURE.md §5.3)
///       → TelnetProcessor          // option negotiation
///       → ANSIParser               // SGR / control chars
///       → LineBuilder              // line assembly
///       → Line
///
/// `SessionController` wraps this with its own actor, an actual
/// ``NetworkConnection`` to read from, and the `scrollbackStore` to
/// write into. Tests and the replay harness use `LinePipeline` directly,
/// driving it from a memory buffer rather than a live socket.
///
/// **Mutating sync**, deliberately. The pipeline is single-consumer by
/// construction — owned by one actor (`SessionController`) or one
/// test scope at a time — so there's no need for actor isolation, and
/// synchronous emit closures keep test code linear.
///
/// `Output` aggregates everything a single ``consume(_:)`` call may
/// have produced: new lines, plus any *server-bound* responses the
/// pipeline wants to send back (currently just telnet negotiation
/// replies). A live session sends responses; a replay typically
/// ignores them.
public struct LinePipeline {
    /// One chunk's-worth of output from a single ``consume(_:)`` call.
    public struct Output: Sendable, Equatable {
        public var lines: [Line]
        public var responses: [[UInt8]]
        public var activatedCompression: Bool
        /// GMCP messages decoded from option-201 subnegotiations this call.
        public var gmcp: [GMCPMessage]
        /// True when this call replied `DO GMCP`, i.e. the server may now
        /// start sending GMCP. The caller should send its GMCP handshake.
        public var enabledGMCP: Bool
        /// True when this call replied `WILL NAWS`, i.e. the server asked for
        /// window size. The caller should send its initial `SB NAWS` now.
        public var enabledNAWS: Bool
        /// Set when the server toggled the telnet ECHO option this call:
        /// `true` on `WILL ECHO` (it's taking over echo — e.g. a password
        /// prompt, so the client should stop local-echoing), `false` on
        /// `WONT ECHO`. `nil` when unchanged.
        public var serverWillEcho: Bool?

        public init(
            lines: [Line] = [],
            responses: [[UInt8]] = [],
            activatedCompression: Bool = false,
            gmcp: [GMCPMessage] = [],
            enabledGMCP: Bool = false,
            enabledNAWS: Bool = false,
            serverWillEcho: Bool? = nil
        ) {
            self.lines = lines
            self.responses = responses
            self.activatedCompression = activatedCompression
            self.gmcp = gmcp
            self.enabledGMCP = enabledGMCP
            self.enabledNAWS = enabledNAWS
            self.serverWillEcho = serverWillEcho
        }
    }

    /// Policy for option-negotiation replies (ARCHITECTURE.md §5.2).
    public enum NegotiationPolicy: Sendable {
        /// Accept MCCP2, refuse everything else (the Phase 2 behaviour).
        case phase2Default
        /// Accept MCCP2 **and** GMCP, refuse everything else. The default
        /// from Phase 4 on — GMCP is critical for Aardwolf.
        case aardwolf

        /// Server-offered (`WILL`) options we agree to (reply `DO`).
        var acceptedWillOptions: Set<UInt8> {
            switch self {
            case .phase2Default: [TelnetOption.mccp2]
            case .aardwolf: [TelnetOption.mccp2, TelnetOption.gmcp]
            }
        }

        /// Server-requested (`DO`) options we agree to provide (reply `WILL`).
        /// Terminal type (MTTS) lets the server learn the client — Aardwolf's
        /// `clients` command keys off the first TTYPE value; we answer the
        /// `SB TTYPE SEND` cycle in ``LinePipeline``.
        var acceptedDoOptions: Set<UInt8> {
            switch self {
            case .phase2Default: []
            case .aardwolf: [TelnetOption.terminalType, TelnetOption.naws]
            }
        }

        func reply(verb: TelnetVerb, option: UInt8) -> [UInt8]? {
            let responseVerb: UInt8
            switch verb {
            case .will:
                responseVerb = acceptedWillOptions.contains(option)
                    ? TelnetCommand.do
                    : TelnetCommand.dont
            case .do:
                responseVerb = acceptedDoOptions.contains(option)
                    ? TelnetCommand.will
                    : TelnetCommand.wont
            case .wont, .dont:
                return nil
            }
            return [TelnetCommand.iac, responseVerb, option]
        }
    }

    public let negotiationPolicy: NegotiationPolicy

    private var telnet = TelnetProcessor()
    private var ansi = ANSIParser()
    private var lineBuilder = LineBuilder()
    private var inflater: Inflater?
    /// Which MTTS response the next `SB TTYPE SEND` should return (0 = client
    /// name, 1 = terminal type, 2/3 = the MTTS bitvector, then reset). See
    /// ``terminalTypeReply()``.
    private var mttsCycle = 0

    /// TTYPE (RFC 1091) subnegotiation qualifiers: `IS` = 0, `SEND` = 1.
    private static let ttypeIS: UInt8 = 0
    private static let ttypeSEND: UInt8 = 1
    /// The client name reported as the first TTYPE — Aardwolf's `clients`
    /// command groups sessions by this value.
    private static let clientName = "Proteles"
    /// MTTS capability bitvector: ANSI (1) + UTF-8 (4) + 256 COLORS (8) +
    /// TRUECOLOR (256). Proteles' ANSI parser handles 8-bit and 24-bit colour
    /// and the app is UTF-8 throughout.
    private static let mttsBitvector = 1 + 4 + 8 + 256

    public init(negotiationPolicy: NegotiationPolicy = .aardwolf) {
        self.negotiationPolicy = negotiationPolicy
    }

    /// True once MCCP2 has been negotiated. Subsequent calls inflate
    /// the wire bytes before parsing.
    public var isCompressionActive: Bool {
        inflater != nil
    }

    /// Text of the line currently being assembled but not yet emitted as
    /// a ``Line``. Combines what the ``LineBuilder`` has accepted with the
    /// tail still buffered inside the ``ANSIParser`` (un-terminated text
    /// is held there until a delimiter). Lets a consumer match prompts
    /// that never arrive as a ``Line`` — e.g. Aardwolf's name/password
    /// prompts.
    public var pendingLineText: String {
        lineBuilder.pendingText + ansi.pendingText
    }

    /// Process one chunk of wire bytes and return everything produced.
    /// Throws only if the MCCP stream is corrupted (which the caller
    /// usually treats as a fatal session error).
    public mutating func consume(_ wireBytes: [UInt8]) throws -> Output {
        var output = Output()

        var buffer = try inflateOrPassThrough(wireBytes)

        var index = 0
        while index < buffer.count {
            // Collect events into a local buffer inside the closure
            // (no mutation of `self`), then drain into `handle` after
            // `processInterruptible` releases its exclusive access.
            var batchEvents: [TelnetEvent] = []
            var activated = false
            let consumed = telnet.processInterruptible(buffer[index...]) { event in
                if Self.isMCCP2Subneg(event) {
                    activated = true
                    return false
                }
                batchEvents.append(event)
                return true
            }
            index += consumed

            for event in batchEvents {
                handle(event, output: &output)
            }

            if activated {
                output.activatedCompression = true
                inflater = try Inflater()
                if index < buffer.count {
                    buffer = try inflateOrPassThrough(Array(buffer[index...]))
                    index = 0
                }
            }
        }

        return output
    }

    /// Decompress `bytes` through the active inflater, or pass them through
    /// untouched when none is active. If the inflater reaches the end of the
    /// compressed stream (MCCP2 ended — e.g. an Aardwolf ice-age copyover), drop
    /// it and append the plaintext tail, so the telnet pass below sees the
    /// server's re-negotiation (a fresh `COMPRESS2` there restarts compression).
    private mutating func inflateOrPassThrough(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let inflater else { return bytes }
        let decompressed = try inflater.inflate(bytes)
        guard inflater.streamEnded else { return decompressed }
        self.inflater = nil
        return decompressed + inflater.leftover
    }

    /// Flush any in-progress line. Use at end-of-stream (disconnect,
    /// end of replay) so a trailing partial line is not silently lost.
    public mutating func flush() -> [Line] {
        var lines: [Line] = []
        drainPending(into: &lines)
        return lines
    }

    /// Drain the parser's in-progress line (ANSI pending text → line builder →
    /// finalise) into `lines`. Emits nothing when there is no pending content.
    /// Shared by ``flush()`` (end-of-stream) and the `IAC GA`/`IAC EOR`
    /// prompt-boundary flush (see ``handle(_:output:)``). Safe mid-stream:
    /// ``ANSIParser/flush(_:)`` only emits pending text, leaving the persisted
    /// colour state intact so subsequent parsing continues correctly.
    private mutating func drainPending(into lines: inout [Line]) {
        ansi.flush { ansiEvent in
            lineBuilder.consume(ansiEvent) { line in lines.append(line) }
        }
        lineBuilder.flush { line in lines.append(line) }
    }

    /// Reset all parser state for a fresh connection or replay.
    public mutating func reset() {
        telnet.reset()
        ansi.reset()
        lineBuilder.reset()
        inflater = nil
    }

    // MARK: - Private

    private static func isMCCP2Subneg(_ event: TelnetEvent) -> Bool {
        if case .subnegotiation(let option, _) = event {
            return option == TelnetOption.mccp2
        }
        return false
    }

    private mutating func handle(
        _ event: TelnetEvent,
        output: inout Output
    ) {
        switch event {
        case .data(let byte):
            // Collect ANSI events first, then drain through line
            // builder — same exclusivity dance as the Telnet pass.
            var ansiEvents: [ANSIEvent] = []
            ansi.process([byte]) { ansiEvents.append($0) }
            for ansiEvent in ansiEvents {
                lineBuilder.consume(ansiEvent) { line in
                    output.lines.append(line)
                }
            }
        case .negotiate(let verb, let option):
            if let reply = negotiationPolicy.reply(verb: verb, option: option) {
                output.responses.append(reply)
            }
            // Accepting the server's WILL GMCP (we reply DO) means the
            // server may now stream GMCP — signal the caller to send its
            // handshake.
            let acceptedGMCP = verb == .will
                && option == TelnetOption.gmcp
                && negotiationPolicy.acceptedWillOptions.contains(TelnetOption.gmcp)
            if acceptedGMCP {
                output.enabledGMCP = true
            }
            // The server asked us to report window size (DO NAWS) and we agreed
            // (WILL NAWS) — signal the caller to send the initial dimensions.
            let acceptedNAWS = verb == .do
                && option == TelnetOption.naws
                && negotiationPolicy.acceptedDoOptions.contains(TelnetOption.naws)
            if acceptedNAWS {
                output.enabledNAWS = true
            }
            // Track the server's ECHO toggle so the host can suppress local
            // echo while the server echoes (password prompts).
            if option == TelnetOption.echo, verb == .will || verb == .wont {
                output.serverWillEcho = verb == .will
            }
        case .subnegotiation(let option, let payload):
            handleSubnegotiation(option: option, payload: payload, into: &output)
        case .command(let byte):
            // `IAC GA` (Go-Ahead) marks a prompt boundary: the server has
            // finished and it's the client's turn. Aardwolf sends GA after
            // every prompt (we never negotiate SUPPRESS-GO-AHEAD), and prompts
            // arrive with no trailing newline. Flushing the pending line here
            // makes a prompt always its *own* `Line` instead of gluing onto the
            // following server output — so anchored triggers (`^…$`) fire
            // reliably without us rewriting the player's server-side prompt to
            // end in `%c` (the invasive trick aard_prompt_fixer used; D-35).
            // `IAC EOR` would mean the same, but we don't negotiate the EOR
            // option, so it never arrives — GA is the live signal.
            if byte == TelnetCommand.ga {
                drainPending(into: &output.lines)
            }
        }
    }

    /// Decode a completed subnegotiation: GMCP payloads become messages; a
    /// `TTYPE SEND` gets the next MTTS value queued as a response.
    private mutating func handleSubnegotiation(option: UInt8, payload: [UInt8], into output: inout Output) {
        if option == TelnetOption.gmcp, let message = GMCPMessage(subnegotiationPayload: payload) {
            output.gmcp.append(message)
        } else if option == TelnetOption.terminalType, payload.first == Self.ttypeSEND {
            // `IAC SB TTYPE SEND IAC SE` → answer with the next MTTS value.
            output.responses.append(terminalTypeReply())
        }
    }

    /// Build the next `IAC SB TTYPE IS <value> IAC SE` reply, cycling through the
    /// MTTS sequence (Mud Terminal Type Standard, as Mudlet/TinTin implement it):
    ///   1. the client name (`Proteles`) — what Aardwolf's `clients` records;
    ///   2. the terminal type (`ANSI-TRUECOLOR`);
    ///   3. `MTTS <bitvector>`, sent twice then reset, so a server that re-`SEND`s
    ///      sees the same value repeated and stops (the MTTS termination rule).
    private mutating func terminalTypeReply() -> [UInt8] {
        let value: String
        switch mttsCycle {
        case 0:
            value = Self.clientName
            mttsCycle = 1
        case 1:
            value = "ANSI-TRUECOLOR"
            mttsCycle = 2
        case 2:
            value = "MTTS \(Self.mttsBitvector)"
            mttsCycle = 3
        default:
            value = "MTTS \(Self.mttsBitvector)" // repeated once, then reset
            mttsCycle = 0
        }
        var reply: [UInt8] = [
            TelnetCommand.iac, TelnetCommand.sb, TelnetOption.terminalType, Self.ttypeIS
        ]
        reply.append(contentsOf: Array(value.utf8))
        reply.append(contentsOf: [TelnetCommand.iac, TelnetCommand.se])
        return reply
    }
}
