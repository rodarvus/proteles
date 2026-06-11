import Foundation
@testable import MudCore
import Testing

/// #58 item: MUSHclient files routinely declare `encoding="iso-8859-1"`, and
/// real third-party plugins can carry Latin-1 high bytes (accented names,
/// `seña`-style trigger text). These fixtures are **actual Latin-1 bytes**,
/// not UTF-8 — the parse must honour the declaration, not assume UTF-8.
@Suite("MUSHclient XML — declared iso-8859-1 with real Latin-1 bytes")
struct MUSHclientXMLEncodingTests {
    /// `é` etc. encoded as single high bytes via `.isoLatin1`.
    private func latin1(_ text: String) -> Data {
        text.data(using: .isoLatin1)!
    }

    @Test("world file: Latin-1 world name survives the parse")
    func worldFileLatin1() throws {
        let mcl = """
        <?xml version="1.0" encoding="iso-8859-1"?>
        <!DOCTYPE muclient>
        <muclient>
        <world name="Café Münz" site="aardmud.org" port="4000" />
        </muclient>
        """
        let world = try #require(MUSHclientWorldParser.parse(latin1(mcl)))
        #expect(world.name == "Café Münz")
        #expect(world.host == "aardmud.org")
    }

    @Test("plugin: Latin-1 attribute values + CDATA script survive the parse")
    func pluginLatin1() throws {
        let xml = """
        <?xml version="1.0" encoding="iso-8859-1"?>
        <!DOCTYPE muclient>
        <muclient>
        <plugin name="Señal" author="José" id="abc123" version="1.0" save_state="y">
        <triggers>
          <trigger enabled="y" regexp="y" match="^the café door opens$" sequence="100">
          <send>say où?</send>
          </trigger>
        </triggers>
        <script>
        <![CDATA[
        greeting = "über alles: é"
        ]]>
        </script>
        </plugin>
        </muclient>
        """
        let plugin = try MUSHclientPluginLoader.parse(latin1(xml))
        #expect(plugin.name == "Señal")
        #expect(plugin.author == "José")
        #expect(plugin.triggers.first?.pattern == .regex("^the café door opens$"))
        #expect(plugin.triggers.first?.sendText?.contains("où") == true)
        #expect(plugin.script.contains("über alles: é"))
    }

    @Test("UTF-8 bytes under a utf-8 declaration still parse (no regression)")
    func utf8Unaffected() throws {
        let mcl = """
        <?xml version="1.0" encoding="utf-8"?>
        <muclient>
        <world name="Café" site="aardmud.org" port="4000" />
        </muclient>
        """
        let world = try #require(MUSHclientWorldParser.parse(Data(mcl.utf8)))
        #expect(world.name == "Café")
    }
}
