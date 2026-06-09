import Foundation

/// A parsed MUSHclient world file (`.mcl`) — the subset Proteles can import.
///
/// MUSHclient stores the world as XML: a `<world>` element carrying ~150
/// connection/display attributes, `<macro>` keypad bindings (each with a
/// `<send>` body), and — for the Aardwolf package style — the behaviour lives in
/// plugins referenced by `<include name="…" plugin="y">`. Triggers/aliases/timers
/// *can* live in the world file too, but in a package-based setup (the common
/// case) they're all in plugins, so the world file is mostly config + macros +
/// the enabled-plugin list. See `mushclient/xml/xml_load_world.cpp` for the
/// authoritative schema.
public struct MUSHclientWorldFile: Sendable, Equatable {
    /// `<world id="…">` — the 24-hex world id; prefixes plugin state filenames
    /// (`{worldID}-{pluginID}-state.xml`).
    public var worldID: String
    /// `<world name="…">` — the display name.
    public var name: String
    /// `<world site="…">` — the hostname Proteles connects to.
    public var host: String
    /// `<world port="…">` — the game port. (Note: distinct from `chat_port`.)
    public var port: UInt16
    /// `<world player="…">` — the autologin character name (not secret).
    public var username: String
    /// `<world password="…">` decoded — the autologin password. **Secret:** the
    /// importer routes this into the Keychain (`CredentialStore`) and it must
    /// never be logged, persisted into the on-disk import manifest, or written to
    /// any tracked file. `nil` when the world has no stored password.
    public var password: String?
    /// Function-key / named macro slots (`<macro>`), in document order.
    public var macros: [Macro]
    /// Numeric-keypad bindings (`<keypad><key name="…"><send>…`), in document
    /// order — MUSHclient keeps these distinct from macros (separate config
    /// page), and Proteles surfaces them as a separate keypad grid.
    public var keypad: [KeypadKey]
    /// `<include name="…" plugin="y">` references, **in load order**, with the
    /// original (possibly Windows `\`-separated, subdir) path preserved — the
    /// scanner resolves these to plugin directories on disk.
    public var pluginIncludes: [String]
    /// World-level `<alias>` rules (those defined on the world itself, not in a
    /// plugin), in document order.
    public var aliases: [ScriptRule]
    /// World-level `<trigger>` rules, in document order.
    public var triggers: [ScriptRule]
    /// World-level `<timer>` rules, in document order.
    public var timers: [Timer]

    public init(
        worldID: String = "",
        name: String = "",
        host: String = "",
        port: UInt16 = 0,
        username: String = "",
        password: String? = nil,
        macros: [Macro] = [],
        keypad: [KeypadKey] = [],
        pluginIncludes: [String] = [],
        aliases: [ScriptRule] = [],
        triggers: [ScriptRule] = [],
        timers: [Timer] = []
    ) {
        self.worldID = worldID
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.macros = macros
        self.keypad = keypad
        self.pluginIncludes = pluginIncludes
        self.aliases = aliases
        self.triggers = triggers
        self.timers = timers
    }

    /// A world-level `<timer>` as stored in the `.mcl`. Either an interval timer
    /// (`hour`/`minute`/`second` + `offset_*`) or an at-time timer (`at_time="y"`,
    /// fires at the wall-clock `hour:minute:second`). Mapped to a Proteles
    /// ``MudTimer``.
    public struct Timer: Sendable, Equatable {
        public var hour: Int
        public var minute: Int
        public var second: Double
        public var offsetHour: Int
        public var offsetMinute: Int
        public var offsetSecond: Double
        public var atTime: Bool
        public var oneShot: Bool
        public var enabled: Bool
        /// `send_to` (MUSHclient `eSendTo`): 0 world (send), 12 script.
        public var sendTo: Int
        public var send: String
        public var name: String?
        public var group: String?

        public init(
            hour: Int = 0,
            minute: Int = 0,
            second: Double = 0,
            offsetHour: Int = 0,
            offsetMinute: Int = 0,
            offsetSecond: Double = 0,
            atTime: Bool = false,
            oneShot: Bool = false,
            enabled: Bool = true,
            sendTo: Int = 0,
            send: String = "",
            name: String? = nil,
            group: String? = nil
        ) {
            self.hour = hour
            self.minute = minute
            self.second = second
            self.offsetHour = offsetHour
            self.offsetMinute = offsetMinute
            self.offsetSecond = offsetSecond
            self.atTime = atTime
            self.oneShot = oneShot
            self.enabled = enabled
            self.sendTo = sendTo
            self.send = send
            self.name = name
            self.group = group
        }
    }

    /// A world-level alias or trigger as stored in the `.mcl` — the raw
    /// MUSHclient attributes the importer maps to a Proteles ``Alias``/``Trigger``.
    public struct ScriptRule: Sendable, Equatable {
        /// `match` — the pattern (wildcard unless `regexp="y"`).
        public var match: String
        /// The `<send>` body.
        public var send: String
        /// `send_to` (MUSHclient `eSendTo`): 0 world, 2 output, 10 execute, 12 script.
        public var sendTo: Int
        public var sequence: Int
        public var enabled: Bool
        public var regexp: Bool
        public var ignoreCase: Bool
        public var keepEvaluating: Bool
        public var group: String?
        public var name: String?

        public init(
            match: String = "",
            send: String = "",
            sendTo: Int = 0,
            sequence: Int = 100,
            enabled: Bool = true,
            regexp: Bool = false,
            ignoreCase: Bool = false,
            keepEvaluating: Bool = false,
            group: String? = nil,
            name: String? = nil
        ) {
            self.match = match
            self.send = send
            self.sendTo = sendTo
            self.sequence = sequence
            self.enabled = enabled
            self.regexp = regexp
            self.ignoreCase = ignoreCase
            self.keepEvaluating = keepEvaluating
            self.group = group
            self.name = name
        }
    }

    /// One `<macro name="…" type="…"><send>…</send></macro>` binding.
    public struct Macro: Sendable, Equatable {
        public var name: String
        public var send: String
        /// MUSHclient macro type, e.g. `send_now` (send immediately).
        public var type: String

        public init(name: String, send: String, type: String) {
            self.name = name
            self.send = send
            self.type = type
        }
    }

    /// One numeric-keypad binding: a key label (`0`–`9`, `/`, `*`, `-`, `+`, `.`)
    /// and the command it sends.
    public struct KeypadKey: Sendable, Equatable {
        public var key: String
        public var send: String

        public init(key: String, send: String) {
            self.key = key
            self.send = send
        }
    }
}

/// Parses a `.mcl` into ``MUSHclientWorldFile``. Tolerant: unknown elements are
/// ignored, missing attributes default. Returns `nil` only if the XML is
/// unparseable.
public enum MUSHclientWorldParser {
    public static func parse(_ data: Data) -> MUSHclientWorldFile? {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.world
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var world = MUSHclientWorldFile()
        private var pendingMacro: MUSHclientWorldFile.Macro?
        private var pendingKey: MUSHclientWorldFile.KeypadKey?
        private var pendingRule: MUSHclientWorldFile.ScriptRule?
        private var pendingTimer: MUSHclientWorldFile.Timer?
        private var inSend = false
        private var sendBuffer = ""

        private static func timer(from attrs: [String: String]) -> MUSHclientWorldFile.Timer {
            func num(_ key: String) -> Double {
                attrs[key].flatMap { Double($0) } ?? 0
            }
            return .init(
                hour: Int(num("hour")),
                minute: Int(num("minute")),
                second: num("second"),
                offsetHour: Int(num("offset_hour")),
                offsetMinute: Int(num("offset_minute")),
                offsetSecond: num("offset_second"),
                atTime: attrs["at_time"]?.lowercased() == "y",
                oneShot: attrs["one_shot"]?.lowercased() == "y",
                enabled: attrs["enabled"]?.lowercased() != "n",
                sendTo: attrs["send_to"].flatMap { Int($0) } ?? 0,
                name: attrs["name"].flatMap { $0.isEmpty ? nil : $0 },
                group: attrs["group"].flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        private static func rule(from attrs: [String: String]) -> MUSHclientWorldFile.ScriptRule {
            .init(
                match: attrs["match"] ?? "",
                sendTo: attrs["send_to"].flatMap { Int($0) } ?? 0,
                sequence: attrs["sequence"].flatMap { Int($0) } ?? 100,
                enabled: attrs["enabled"]?.lowercased() != "n",
                regexp: attrs["regexp"]?.lowercased() == "y",
                ignoreCase: attrs["ignore_case"]?.lowercased() == "y",
                keepEvaluating: attrs["keep_evaluating"]?.lowercased() == "y",
                group: attrs["group"].flatMap { $0.isEmpty ? nil : $0 },
                name: attrs["name"].flatMap { $0.isEmpty ? nil : $0 }
            )
        }

        private func applyWorldAttributes(_ attrs: [String: String]) {
            world.worldID = attrs["id"] ?? world.worldID
            world.name = attrs["name"] ?? world.name
            world.host = attrs["site"] ?? attrs["host"] ?? world.host
            if let port = attrs["port"], let value = UInt16(port) { world.port = value }
            world.username = attrs["player"] ?? world.username
            if let stored = attrs["password"], !stored.isEmpty {
                world.password = Self.decodePassword(
                    stored, base64: attrs["password_base64"]?.lowercased() == "y"
                )
            }
        }

        func parser(
            _: XMLParser,
            didStartElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes attrs: [String: String]
        ) {
            switch element {
            case "world":
                applyWorldAttributes(attrs)
            case "macro":
                pendingMacro = .init(name: attrs["name"] ?? "", send: "", type: attrs["type"] ?? "")
            case "key":
                pendingKey = .init(key: attrs["name"] ?? "", send: "")
            case "alias", "trigger":
                pendingRule = Self.rule(from: attrs)
            case "timer":
                pendingTimer = Self.timer(from: attrs)
            case "send" where pendingMacro != nil || pendingKey != nil
                || pendingRule != nil || pendingTimer != nil:
                inSend = true
                sendBuffer = ""
            case "include" where attrs["plugin"]?.lowercased() == "y":
                if let name = attrs["name"], !name.isEmpty { world.pluginIncludes.append(name) }
            default:
                break
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            if inSend { sendBuffer += string }
        }

        func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
            if inSend, let string = String(data: CDATABlock, encoding: .utf8) { sendBuffer += string }
        }

        /// Decode MUSHclient's stored password (base64 when `password_base64="y"`).
        private static func decodePassword(_ stored: String, base64: Bool) -> String {
            guard base64,
                  let data = Data(base64Encoded: stored),
                  let decoded = String(data: data, encoding: .utf8)
            else { return stored }
            return decoded
        }

        /// Route a finished `<send>` body to whichever rule/timer/macro/key is pending.
        private func assignSend(_ buffer: String) {
            if pendingTimer != nil {
                pendingTimer?.send = buffer
            } else if pendingRule != nil {
                pendingRule?.send = buffer
            } else if pendingKey != nil {
                pendingKey?.send = buffer
            } else {
                pendingMacro?.send = buffer
            }
        }

        func parser(
            _: XMLParser,
            didEndElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            switch element {
            case "send" where inSend:
                inSend = false
                assignSend(sendBuffer)
            case "macro":
                pendingMacro.map { world.macros.append($0) }
                pendingMacro = nil
            case "key":
                pendingKey.map { world.keypad.append($0) }
                pendingKey = nil
            case "alias":
                pendingRule.map { world.aliases.append($0) }
                pendingRule = nil
            case "trigger":
                pendingRule.map { world.triggers.append($0) }
                pendingRule = nil
            case "timer":
                pendingTimer.map { world.timers.append($0) }
                pendingTimer = nil
            default:
                break
            }
        }
    }
}
