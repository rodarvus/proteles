import Foundation
@testable import MudCore
import Testing

/// End-to-end: a MUSHclient plugin that draws a miniwindow in `OnPluginInstall`,
/// loaded through the real XML-parse → install pipeline, must produce an
/// `.updateMiniWindow` effect carrying its scene. Mirrors how the sample plugins
/// under `samples/miniwindow-plugins/` run.
@Suite("MiniWindow — plugin install pipeline")
struct MiniWindowPluginTests {
    private func scene(in effects: [ScriptEffect], named name: String) -> MiniWindowScene? {
        for effect in effects {
            if case .updateMiniWindow(let scene) = effect, scene.name == name { return scene }
        }
        return nil
    }

    @Test("a plugin's WindowCreate + draws in OnPluginInstall reach an updateMiniWindow effect")
    func drawsOnInstall() async throws {
        let xml = """
        <muclient><plugin id="aaaaaaaaaaaaaaaaaaaaaaaa" name="MWTest"/>
        <script><![CDATA[
        function OnPluginInstall()
          WindowCreate("w", 0, 0, 120, 40, miniwin.pos_top_left, 0, 0x101010)
          WindowFont("w", "f", "Menlo", 11)
          WindowRectOp("w", miniwin.rect_fill, 0, 0, 0, 0, 0x202020)
          WindowText("w", "f", "hi", 4, 4, 0, 0, 0xFFFFFF)
          WindowAddHotspot("w", "h", 0, 0, 120, 40, "", "", "", "", "onUp", "tip", miniwin.cursor_hand, 0)
        end
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let effects = await engine.loadPlugin(plugin)
        let scene = scene(in: effects, named: "w")
        #expect(scene != nil, "expected an updateMiniWindow effect; got \(effects)")
        #expect(scene?.width == 120)
        #expect(scene?.pluginID == "aaaaaaaaaaaaaaaaaaaaaaaa") // owner recorded for hotspot dispatch
        // create-fill + our fill + text == 3 draw commands.
        #expect(scene?.commands.count == 3)
        #expect(scene?.hotspots.first?.mouseUp == "onUp")
    }

    @Test("unloading a plugin emits deleteMiniWindow for each window it owned")
    func unloadRemovesWindows() async throws {
        let xml = """
        <muclient><plugin id="cccccccccccccccccccccccc" name="MWUnload"/>
        <script><![CDATA[
        function OnPluginInstall()
          WindowCreate("u1", 0, 0, 40, 40, 4, 0, 0)
          WindowCreate("u2", 0, 0, 40, 40, 8, 0, 0)
        end
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        _ = await engine.loadPlugin(plugin)
        let effects = await engine.unloadPlugin("cccccccccccccccccccccccc")
        let deleted = Set(effects.compactMap { effect -> String? in
            if case .deleteMiniWindow(let name) = effect { return name }
            return nil
        })
        #expect(deleted == ["u1", "u2"])
    }

    @Test("the owning plugin id flows onto the hotspot, so dispatch can route back")
    func ownerRecorded() async throws {
        let xml = """
        <muclient><plugin id="bbbbbbbbbbbbbbbbbbbbbbbb" name="MWOwner"/>
        <script><![CDATA[
        function OnPluginInstall()
          WindowCreate("o", 0, 0, 50, 50, 4, 0, 0)
          WindowAddHotspot("o", "x", 0, 0, 50, 50, "", "", "", "", "click", "", 1, 0)
        end
        function click() Note("clicked") end
        ]]></script>
        </muclient>
        """
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: xml)
        let effects = await engine.loadPlugin(plugin)
        let scene = scene(in: effects, named: "o")
        #expect(scene?.pluginID == "bbbbbbbbbbbbbbbbbbbbbbbb")
        // Calling the registered callback by name in the plugin env produces the
        // note — the exact path SessionController.dispatchMiniWindowEvent uses.
        let callbackEffects = await engine.callPluginFunction(
            "bbbbbbbbbbbbbbbbbbbbbbbb", "click", [.number(0), .string("x")]
        )
        let notes = callbackEffects.compactMap { effect -> String? in
            if case .echo(let text) = effect { return text }
            if case .note(let text, _, _) = effect { return text }
            return nil
        }
        #expect(notes.contains("clicked"))
    }

    @Test("miniwindow list/info/image queries reflect retained scene state")
    func listAndImageQueries() async throws {
        let engine = try ScriptEngine()
        let plugin = try MUSHclientPluginLoader.parse(xml: Self.listAndImageXML)
        let installEffects = await engine.loadPlugin(plugin)
        #expect(installEffects.contains(.send("window=w")))
        #expect(installEffects.contains(.send("font=f")))
        #expect(installEffects.contains(.send("image=img")))
        #expect(installEffects.contains(.send("hotspot=h")))
        #expect(installEffects.contains(.send("bounds=10,20,130,60")))
        #expect(installEffects.contains(.send("owner=dddddddddddddddddddddddd")))
        #expect(installEffects.contains(.send("imgsize=1x1")))

        let event = MiniWindowEvent(
            windowName: "w",
            pluginID: "dddddddddddddddddddddddd",
            hotspotID: "h",
            kind: .mouseDown,
            callback: "onDown",
            flags: 0,
            x: 7,
            y: 8
        )
        let callbackEffects = await engine.callPluginFunction(
            "dddddddddddddddddddddddd",
            "onDown",
            [.number(0), .string("h")],
            event: event
        )
        #expect(callbackEffects.contains(.send("pointer=7,8,7,8,h,h")))

        let scrollEvent = MiniWindowEvent(
            windowName: "w",
            pluginID: "dddddddddddddddddddddddd",
            hotspotID: "h",
            kind: .scrollwheel,
            callback: "onWheel",
            flags: 0x100 | (120 << 16),
            x: 9,
            y: 10
        )
        let scrollEffects = await engine.callPluginFunction(
            "dddddddddddddddddddddddd",
            "onWheel",
            [.number(Double(scrollEvent.flags)), .string("h")],
            event: scrollEvent
        )
        #expect(scrollEffects.contains(.send("wheel=true,120,7,8,9,10,h,h")))
    }

    private static let listAndImageXML = """
    <muclient><plugin id="dddddddddddddddddddddddd" name="MWLists"/>
    <script><![CDATA[
    function OnPluginInstall()
      WindowCreate("w", 10, 20, 120, 40, miniwin.pos_top_left, 0, 0x101010)
      WindowFont("w", "f", "Menlo", 11)
      local png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ" ..
        "AAAADUlEQVR42mP8z8BQDwAFgwJ/lD0RTwAAAABJRU5ErkJggg=="
      WindowLoadImageMemory("w", "img", png)
      WindowAddHotspot("w", "h", 0, 0, 120, 40, "", "", "onDown", "", "", "tip", miniwin.cursor_hand, 0)
      WindowScrollwheelHandler("w", "h", "onWheel")
      local windows = WindowList()
      local fonts = WindowFontList("w")
      local images = WindowImageList("w")
      local hotspots = WindowHotspotList("w")
      Send("window=" .. tostring(windows[1]))
      Send("font=" .. tostring(fonts[1]))
      Send("image=" .. tostring(images[1]))
      Send("hotspot=" .. tostring(hotspots[1]))
      Send("bounds=" .. tostring(WindowInfo("w", 10)) .. "," .. tostring(WindowInfo("w", 11)) .. "," ..
        tostring(WindowInfo("w", 12)) .. "," .. tostring(WindowInfo("w", 13)))
      Send("owner=" .. tostring(WindowInfo("w", 23)))
      Send("imgsize=" .. tostring(WindowImageInfo("w", "img", 2)) .. "x" ..
        tostring(WindowImageInfo("w", "img", 3)))
    end
    function onDown(flags, id)
      Send("pointer=" .. tostring(WindowInfo("w", 14)) .. "," .. tostring(WindowInfo("w", 15)) .. "," ..
        tostring(WindowInfo("w", 17)) .. "," .. tostring(WindowInfo("w", 18)) .. "," ..
        tostring(WindowInfo("w", 19)) .. "," .. tostring(WindowInfo("w", 20)))
    end
    function onWheel(flags, id)
      Send("wheel=" .. tostring(bit.band(flags, miniwin.wheel_scroll_back) ~= 0) .. "," ..
        tostring(bit.rshift(flags, 16)) .. "," .. tostring(WindowInfo("w", 14)) .. "," ..
        tostring(WindowInfo("w", 15)) .. "," .. tostring(WindowInfo("w", 17)) .. "," ..
        tostring(WindowInfo("w", 18)) .. "," .. tostring(WindowInfo("w", 19)) .. "," ..
        tostring(WindowInfo("w", 20)))
    end
    ]]></script>
    </muclient>
    """
}
