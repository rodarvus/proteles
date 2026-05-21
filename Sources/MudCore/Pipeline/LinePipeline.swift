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

        public init(
            lines: [Line] = [],
            responses: [[UInt8]] = [],
            activatedCompression: Bool = false
        ) {
            self.lines = lines
            self.responses = responses
            self.activatedCompression = activatedCompression
        }
    }

    /// Policy for option-negotiation replies. Phase 2 accepts MCCP2
    /// and refuses everything else (PLAN.md §5.2); other phases will
    /// extend the table.
    public enum NegotiationPolicy: Sendable {
        case phase2Default

        func reply(verb: TelnetVerb, option: UInt8) -> [UInt8]? {
            switch self {
            case .phase2Default:
                let responseVerb: UInt8
                switch verb {
                case .will:
                    responseVerb = option == TelnetOption.mccp2
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
    }

    public let negotiationPolicy: NegotiationPolicy

    private var telnet = TelnetProcessor()
    private var ansi = ANSIParser()
    private var lineBuilder = LineBuilder()
    private var inflater: Inflater?

    public init(negotiationPolicy: NegotiationPolicy = .phase2Default) {
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
        case .command, .subnegotiation:
            break
        }
    }
}
