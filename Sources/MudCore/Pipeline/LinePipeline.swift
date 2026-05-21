import Foundation

/// Synchronous, value-type pipeline that turns raw wire bytes into
/// ``Line`` records.
///
/// Composes the four parsers in the order they appear on the inbound
/// path:
///
///     wire bytes
///       → (optional) Inflater     // MCCP2 (PLAN.md §5.3)
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

        public init(
            lines: [Line] = [],
            responses: [[UInt8]] = [],
            activatedCompression: Bool = false,
            gmcp: [GMCPMessage] = [],
            enabledGMCP: Bool = false
        ) {
            self.lines = lines
            self.responses = responses
            self.activatedCompression = activatedCompression
            self.gmcp = gmcp
            self.enabledGMCP = enabledGMCP
        }
    }

    /// Policy for option-negotiation replies (PLAN.md §5.2).
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

        func reply(verb: TelnetVerb, option: UInt8) -> [UInt8]? {
            let responseVerb: UInt8
            switch verb {
            case .will:
                responseVerb = acceptedWillOptions.contains(option)
                    ? TelnetCommand.do
                    : TelnetCommand.dont
            case .do:
                responseVerb = TelnetCommand.wont
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

        var buffer: [UInt8] = if let inflater {
            try inflater.inflate(wireBytes)
        } else {
            wireBytes
        }

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
                let newInflater = try Inflater()
                inflater = newInflater
                if index < buffer.count {
                    let remainder = Array(buffer[index...])
                    buffer = try newInflater.inflate(remainder)
                    index = 0
                }
            }
        }

        return output
    }

    /// Flush any in-progress line. Use at end-of-stream (disconnect,
    /// end of replay) so a trailing partial line is not silently lost.
    public mutating func flush() -> [Line] {
        var lines: [Line] = []
        ansi.flush { ansiEvent in
            lineBuilder.consume(ansiEvent) { line in lines.append(line) }
        }
        lineBuilder.flush { line in lines.append(line) }
        return lines
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
        case .subnegotiation(let option, let payload):
            if option == TelnetOption.gmcp, let message = GMCPMessage(subnegotiationPayload: payload) {
                output.gmcp.append(message)
            }
        case .command:
            break
        }
    }
}
