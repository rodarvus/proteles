import Foundation

/// Incremental Telnet protocol processor (RFC 854).
///
/// Consumes a raw byte stream from a MUD server and emits ``TelnetEvent``
/// values via a caller-supplied closure. The processor is **stateful
/// across calls** — feed bytes as they arrive in whatever chunk sizes
/// `NWConnection` delivers; the state machine correctly handles partial
/// sequences spanning chunks, IAC escape doubling (`IAC IAC` → `0xFF`),
/// and IAC inside subnegotiation payloads.
///
/// The processor does **not** interpret option negotiation policy — it
/// only parses the wire format. The session controller decides whether to
/// accept or refuse each negotiation event.
///
/// Malformed-input policy (PLAN.md §9.6): the processor never panics,
/// never reads past the input slice, and recovers conservatively. If an
/// `IAC` byte inside an active subnegotiation is followed by something
/// other than `IAC` or `SE`, the in-progress subnegotiation is
/// terminated with whatever payload was collected so far and the
/// offending byte is re-processed from ground state.
public struct TelnetProcessor: Sendable {
    private enum State: Equatable {
        case ground
        case iac
        case negotiation(verb: UInt8)
        case subnegotiation
        case subnegotiationIAC
    }

    private var state: State = .ground
    private var subnegOption: UInt8?
    private var subnegBuffer: [UInt8] = []

    public init() {}

    /// Feed bytes into the processor. The `emit` closure is called once
    /// per event, in arrival order.
    public mutating func process(
        _ bytes: some Sequence<UInt8>,
        emit: (TelnetEvent) -> Void
    ) {
        for byte in bytes {
            processSingle(byte, emit: emit)
        }
    }

    /// Process bytes one event at a time. The `emit` closure returns
    /// `false` to halt processing immediately — useful when a single
    /// event needs to switch the byte source mid-stream (the canonical
    /// case: MCCP2 activation, where the next byte is the first
    /// compressed octet).
    ///
    /// Returns the number of input bytes consumed before halting. The
    /// caller can resume by feeding `bytes[consumed...]` through the
    /// new byte source.
    @discardableResult
    public mutating func processInterruptible(
        _ bytes: some Collection<UInt8>,
        emit: (TelnetEvent) -> Bool
    ) -> Int {
        var consumed = 0
        var halt = false
        for byte in bytes {
            if halt { break }
            processSingle(byte) { event in
                if !emit(event) { halt = true }
            }
            consumed += 1
        }
        return consumed
    }

    /// Reset all internal state. Call between connections.
    public mutating func reset() {
        state = .ground
        subnegOption = nil
        subnegBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Private

    private mutating func processSingle(
        _ byte: UInt8,
        emit: (TelnetEvent) -> Void
    ) {
        switch state {
        case .ground:
            processGround(byte, emit: emit)
        case .iac:
            processAfterIAC(byte, emit: emit)
        case .negotiation(let verb):
            processNegotiation(verb: verb, option: byte, emit: emit)
        case .subnegotiation:
            processSubnegotiation(byte)
        case .subnegotiationIAC:
            processSubnegotiationIAC(byte, emit: emit)
        }
    }

    private mutating func processGround(
        _ byte: UInt8,
        emit: (TelnetEvent) -> Void
    ) {
        if byte == TelnetCommand.iac {
            state = .iac
        } else {
            emit(.data(byte))
        }
    }

    private mutating func processAfterIAC(
        _ byte: UInt8,
        emit: (TelnetEvent) -> Void
    ) {
        switch byte {
        case TelnetCommand.iac:
            // IAC IAC — escaped data byte 0xFF.
            emit(.data(0xFF))
            state = .ground
        case TelnetCommand.will,
             TelnetCommand.wont,
             TelnetCommand.do,
             TelnetCommand.dont:
            state = .negotiation(verb: byte)
        case TelnetCommand.sb:
            subnegOption = nil
            subnegBuffer.removeAll(keepingCapacity: true)
            state = .subnegotiation
        default:
            // Standalone command (NOP, GA, AYT, EC, EL, BRK, DM, …) or an
            // unexpected command byte. Emit and return to ground.
            emit(.command(byte))
            state = .ground
        }
    }

    private mutating func processNegotiation(
        verb: UInt8,
        option: UInt8,
        emit: (TelnetEvent) -> Void
    ) {
        if let verbEnum = TelnetVerb(rawValue: verb) {
            emit(.negotiate(verb: verbEnum, option: option))
        }
        state = .ground
    }

    private mutating func processSubnegotiation(_ byte: UInt8) {
        if subnegOption == nil {
            subnegOption = byte
        } else if byte == TelnetCommand.iac {
            state = .subnegotiationIAC
        } else {
            subnegBuffer.append(byte)
        }
    }

    private mutating func processSubnegotiationIAC(
        _ byte: UInt8,
        emit: (TelnetEvent) -> Void
    ) {
        switch byte {
        case TelnetCommand.iac:
            // Escaped 0xFF inside subneg payload.
            subnegBuffer.append(0xFF)
            state = .subnegotiation
        case TelnetCommand.se:
            emit(.subnegotiation(
                option: subnegOption ?? 0,
                payload: subnegBuffer
            ))
            subnegOption = nil
            subnegBuffer.removeAll(keepingCapacity: true)
            state = .ground
        default:
            // Malformed: IAC followed by something other than IAC or SE
            // inside SB. Terminate the subneg with what we have, return
            // to ground, and re-process the offending byte.
            emit(.subnegotiation(
                option: subnegOption ?? 0,
                payload: subnegBuffer
            ))
            subnegOption = nil
            subnegBuffer.removeAll(keepingCapacity: true)
            state = .ground
            processSingle(byte, emit: emit)
        }
    }
}
