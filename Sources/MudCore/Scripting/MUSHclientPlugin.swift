import Foundation

/// A parsed MUSHclient plugin: its metadata, the triggers/aliases/timers it
/// declares (already mapped to Proteles' value types), and its Lua script
/// source (PLAN.md §7.4). Produced by ``MUSHclientPluginLoader`` from a
/// `.xml` plugin file; the plugin *runtime host* (next increment) installs
/// the script + helper libs and drives lifecycle callbacks.
public struct MUSHclientPlugin: Sendable, Equatable {
    public var id: String
    public var name: String
    public var author: String
    public var version: String
    public var purpose: String
    public var requires: String
    /// `save_state="y"` — whether the plugin's variables persist.
    public var savesState: Bool
    /// Plugin load-order hint (`sequence` on `<plugin>`).
    public var sequence: Int
    /// The `<script>` CDATA source.
    public var script: String
    public var triggers: [Trigger]
    public var aliases: [Alias]
    public var timers: [MudTimer]

    public init(
        id: String = "",
        name: String = "",
        author: String = "",
        version: String = "",
        purpose: String = "",
        requires: String = "",
        savesState: Bool = false,
        sequence: Int = 0,
        script: String = "",
        triggers: [Trigger] = [],
        aliases: [Alias] = [],
        timers: [MudTimer] = []
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.purpose = purpose
        self.requires = requires
        self.savesState = savesState
        self.sequence = sequence
        self.script = script
        self.triggers = triggers
        self.aliases = aliases
        self.timers = timers
    }
}

/// Parses a MUSHclient `.xml` plugin into a ``MUSHclientPlugin``.
///
/// Uses `XMLParser` (SAX) — available on every Apple platform, unlike the
/// macOS-only `XMLDocument` — so the loader ports to iOS unchanged. Maps the
/// attributes the Aardwolf corpus actually uses: `regexp`, `match`,
/// `sequence`, `ignore_case`, `keep_evaluating`, `omit_from_output`,
/// `enabled`, `group`, `name`, `send_to`, and the `script` function
/// attribute. `send_to="12"`/`"14"` (the only values the corpus uses) route
/// the `<send>` body to the script; a `script="Fn"` attribute generates a
/// MUSHclient-style `Fn(name, line, wildcards)` call.
public enum MUSHclientPluginLoader {
    public enum ParseError: Error, Equatable {
        case malformedXML(String)
        case missingPlugin
    }

    public static func parse(xml: String) throws -> MUSHclientPlugin {
        try parse(Data(xml.utf8))
    }

    /// The per-world plugins directory:
    /// `~/Library/Application Support/com.proteles.ProtelesApp/plugins/<id>/`.
    /// Drop `.xml` plugin files here; created on demand. `nil` only if
    /// Application Support is unavailable.
    public static func defaultDirectory(
        forProfile id: UUID,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        let folder = support
            .appendingPathComponent("com.proteles.ProtelesApp", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public static func parse(_ data: Data) throws -> MUSHclientPlugin {
        // MUSHclient's lenient XML reader allows raw `<`/`>` inside attribute
        // values (e.g. PCRE named-group regexes `(?<n>…)` in a trigger `match`),
        // which strict XMLParser rejects; escape those up front so such plugins
        // import without mangling their patterns.
        let parser = XMLParser(data: MUSHclientXMLSanitizer.lenientAttributeData(data))
        let delegate = PluginParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError.malformedXML(
                parser.parserError?.localizedDescription ?? "unknown XML error"
            )
        }
        guard let attributes = delegate.pluginAttributes else {
            throw ParseError.missingPlugin
        }
        return MUSHclientPlugin(
            id: attributes["id"] ?? "",
            name: attributes["name"] ?? "",
            author: attributes["author"] ?? "",
            version: attributes["version"] ?? "",
            purpose: attributes["purpose"] ?? "",
            requires: attributes["requires"] ?? "",
            savesState: attributes["save_state"] == "y",
            sequence: Int(attributes["sequence"] ?? "") ?? 0,
            script: delegate.script,
            triggers: delegate.triggers,
            aliases: delegate.aliases,
            timers: delegate.timers
        )
    }
}

/// SAX delegate that accumulates the plugin's parts. Used synchronously
/// inside `parse(_:)` and never escapes, so its mutable state is safe.
private final class PluginParserDelegate: NSObject, XMLParserDelegate {
    var pluginAttributes: [String: String]?
    var triggers: [Trigger] = []
    var aliases: [Alias] = []
    var timers: [MudTimer] = []
    var script = ""

    private var currentElementAttributes: [String: String]?
    private var sendBuffer = ""
    private var inSend = false
    private var inScript = false

    func parser(
        _: XMLParser,
        didStartElement element: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String]
    ) {
        switch element {
        case "plugin":
            pluginAttributes = attributes
        case "trigger", "alias", "timer":
            currentElementAttributes = attributes
            sendBuffer = ""
        case "send":
            inSend = true
            sendBuffer = ""
        case "script":
            inScript = true
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if inSend { sendBuffer += string } else if inScript { script += string }
    }

    func parser(_: XMLParser, foundCDATA CDATABlock: Data) {
        let text = String(decoding: CDATABlock, as: UTF8.self)
        if inSend { sendBuffer += text } else if inScript { script += text }
    }

    func parser(
        _: XMLParser,
        didEndElement element: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        switch element {
        case "send":
            inSend = false
        case "script":
            inScript = false
            script = script.trimmingCharacters(in: .whitespacesAndNewlines)
        case "trigger":
            if let attributes = currentElementAttributes {
                triggers.append(PluginMapping.trigger(attributes, send: sendBuffer))
            }
            currentElementAttributes = nil
        case "alias":
            if let attributes = currentElementAttributes {
                aliases.append(PluginMapping.alias(attributes, send: sendBuffer))
            }
            currentElementAttributes = nil
        case "timer":
            if let attributes = currentElementAttributes {
                if let timer = PluginMapping.timer(attributes, send: sendBuffer) {
                    timers.append(timer)
                }
            }
            currentElementAttributes = nil
        default:
            break
        }
    }
}
