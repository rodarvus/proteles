import Foundation

/// A value crossing the Lua ↔ Swift boundary. The minimal set the host
/// API needs today (scalars); tables follow when the event bus / RPC land.
public enum LuaValue: Sendable, Equatable {
    case `nil`
    case boolean(Bool)
    case number(Double)
    case string(String)
    /// A reference to a Lua function held in the registry (`luaL_ref`), so
    /// Swift can store it (event handlers, exported callables) and invoke
    /// it later. Opaque handle — not meant to be inspected.
    case functionRef(Int32)

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var numberValue: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var booleanValue: Bool? {
        if case .boolean(let value) = self { value } else { nil }
    }
}

/// A side effect a script asked the host to perform, recorded while a Lua
/// chunk runs and applied by the host (the session) after it returns.
///
/// Keeping these as inert values — rather than letting Lua call the
/// (async) network/scrollback APIs directly from inside `pcall` — keeps
/// the C↔Swift boundary synchronous and the script engine unit-testable
/// without a live session.
public enum ScriptEffect: Sendable, Equatable {
    /// Send a command to the MUD (raw, as `proteles.send`).
    case send(String)
    /// Send without local echo (passwords).
    case sendNoEcho(String)
    /// Run a command as if the user typed it (through aliases).
    case execute(String)
    /// Print plain text to the scrollback.
    case echo(String)
    /// Print coloured text to the scrollback. `foreground`/`background`
    /// are colour names (resolved by the host); `nil` uses defaults.
    case note(text: String, foreground: String?, background: String?)
    /// Send a GMCP packet to the server (the payload is framed as
    /// `IAC SB 201 <payload> IAC SE`). Backs `Send_GMCP_Packet`.
    case sendGMCP(String)
    /// Print Aardwolf `@`-coded text to the scrollback, rendered as styled
    /// runs (`proteles.echoAard`).
    case echoAard(String)
    /// Print ANSI-SGR-coded text to the scrollback, rendered as styled runs
    /// (the shim's `AnsiNote`).
    case echoAnsi(String)
}
