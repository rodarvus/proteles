import Foundation

/// Reads a MUSHclient plugin **state file** (`{worldID}-{pluginID}-state.xml`),
/// whose payload is `<muclient><variables><variable name="…">value</variable>…`.
/// On import these seed the variable store so a third-party plugin resumes with
/// its saved state (the "net new" import item).
public enum MUSHclientStateFile {
    /// Parse the `<variables>` into name → value. Empty on unparseable input.
    public static func parseVariables(_ data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return [:] }
        return delegate.variables
    }

    /// Recover the plugin id from a `{worldID}-{pluginID}-state.xml` filename.
    /// Returns nil when the name isn't a state file.
    public static func pluginID(fromFilename name: String, worldID: String) -> String? {
        let suffix = "-state.xml"
        guard name.hasSuffix(suffix) else { return nil }
        var core = String(name.dropLast(suffix.count))
        let prefix = worldID + "-"
        if !worldID.isEmpty, core.hasPrefix(prefix) { core = String(core.dropFirst(prefix.count)) }
        return core.isEmpty ? nil : core
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var variables: [String: String] = [:]
        private var currentName: String?
        private var buffer = ""

        func parser(
            _: XMLParser,
            didStartElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?,
            attributes attrs: [String: String]
        ) {
            if element == "variable" {
                currentName = attrs["name"]
                buffer = ""
            }
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            if currentName != nil { buffer += string }
        }

        func parser(_: XMLParser, foundCDATA block: Data) {
            guard currentName != nil else { return }
            buffer += String(data: block, encoding: .utf8)
                ?? String(data: block, encoding: .isoLatin1) ?? ""
        }

        func parser(
            _: XMLParser,
            didEndElement element: String,
            namespaceURI _: String?,
            qualifiedName _: String?
        ) {
            if element == "variable", let name = currentName {
                variables[name] = buffer
                currentName = nil
            }
        }
    }
}
