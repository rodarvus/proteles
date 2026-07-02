import Foundation
@testable import MudCore
import Testing

/// The `async` HTTP helper end-to-end: a plugin's `doAsyncRemoteRequest`
/// performs a request through an injected ``HTTPClient`` and the host re-enters
/// the engine to fire the plugin's Lua callback — driving the real
/// ``SessionController`` + ``LuaRuntime`` path (no live network).
@Suite("async HTTP — request → callback", .serialized)
struct AsyncHTTPTests {
    /// A canned HTTP client; records requests, returns a fixed response.
    final class StubHTTPClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private let response: HTTPResponse
        private var seen: [HTTPRequest] = []

        init(_ response: HTTPResponse) {
            self.response = response
        }

        var requests: [HTTPRequest] {
            lock.withLock { seen }
        }

        func perform(_ request: HTTPRequest) async -> HTTPResponse {
            lock.withLock { seen.append(request) }
            return response
        }
    }

    /// Poll `condition` until true or the deadline — the HTTP completion fires
    /// on a detached task, so the assertion must wait for it.
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func plugin(_ body: String, id: String = "cccccccccccccccccccccccc") -> String {
        """
        <muclient>
        <plugin id="\(id)" name="Net"/>
        <aliases><alias match="^go$" enabled="y" regexp="y" send_to="12" script="go"/></aliases>
        <script><![CDATA[
        require "async"
        \(body)
        ]]></script>
        </muclient>
        """
    }

    @Test("doAsyncRemoteRequest fires the callback with the response")
    func requestFiresCallback() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin("""
        function go()
          async.doAsyncRemoteRequest("https://example.com/x", function(retval, page, status)
            Send("got:" .. tostring(page) .. ":" .. tostring(status))
          end, "HTTPS", 5)
        end
        """)))
        let conn = InMemoryConnection()
        let client = StubHTTPClient(HTTPResponse(
            retval: 1, page: "OK", status: 200, headers: "", fullStatus: "HTTP 200", timedOut: false
        ))
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn }, httpClient: client)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("go")

        #expect(await eventually { conn.sentLines.contains("got:OK:200") })
        #expect(client.requests.first?.method == .post ? false : true) // GET (no body)
        await controller.disconnect()
    }

    @Test("async callbacks keep the requesting plugin's context after another plugin loads")
    func callbackPreservesPluginContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("async-http-context-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        let lastDataDir = root.appendingPathComponent("last-data", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lastDataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceXML = sourceDir.appendingPathComponent("source.xml")
        let wrongFallback = lastDataDir.appendingPathComponent("source.xml")
        try "original".write(to: sourceXML, atomically: true, encoding: .utf8)

        let engine = try ScriptEngine()
        await engine.setSQLiteDirectory(root.path)
        let requestingPlugin = try MUSHclientPluginLoader.parse(xml: plugin("""
        function go()
          async.doAsyncRemoteRequest("https://example.com/source", function(retval, page, status)
            local path = GetPluginInfo(GetPluginID(), 6)
            if not path or path == "" then
              path = GetPluginInfo(GetPluginID(), 20) .. "source.xml"
            end
            local f = assert(io.open(path, "wb"))
            f:write(page)
            f:close()
            SetVariable("callback_owner", GetPluginID())
            Send("wrote:" .. tostring(path))
          end, "HTTPS", 5)
        end
        """, id: "com.test.net"))
        _ = await engine.loadPlugin(requestingPlugin, context: PluginContext(
            pluginID: requestingPlugin.id,
            pluginName: requestingPlugin.name,
            pluginSourceFile: sourceXML.path,
            pluginDirectory: sourceDir.path + "/"
        ))

        let lastPlugin = try MUSHclientPluginLoader.parse(xml: """
        <muclient>
        <plugin id="com.test.last" name="Last"/>
        <script><![CDATA[]]></script>
        </muclient>
        """)
        _ = await engine.loadPlugin(lastPlugin, context: PluginContext(
            pluginID: lastPlugin.id,
            pluginName: lastPlugin.name,
            pluginDirectory: lastDataDir.path + "/"
        ))

        let conn = InMemoryConnection()
        let client = StubHTTPClient(HTTPResponse(
            retval: 1, page: "updated", status: 200, headers: "", fullStatus: "HTTP 200", timedOut: false
        ))
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn }, httpClient: client)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("go")

        #expect(await eventually {
            (try? String(contentsOf: sourceXML, encoding: .utf8)) == "updated"
        })
        #expect(!FileManager.default.fileExists(atPath: wrongFallback.path))
        let variables = await engine.variablesSnapshot()
        #expect(variables["com.test.net"]?["callback_owner"] == "com.test.net")
        #expect(variables["com.test.last"]?["callback_owner"] == nil)
        await controller.disconnect()
    }

    @Test("A POST body is sent and a timeout routes to the timeout callback")
    func postAndTimeout() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin("""
        function go()
          async.doAsyncRemoteRequest("http://example.com/p", function() end, "HTTP", 1,
            function(url) Send("timeout:" .. tostring(url)) end, "payload=1")
        end
        """)))
        let conn = InMemoryConnection()
        let client = StubHTTPClient(HTTPResponse(
            retval: 0, page: "", status: 0, headers: "", fullStatus: "timed out", timedOut: true
        ))
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn }, httpClient: client)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("go")

        #expect(await eventually { conn.sentLines.contains("timeout:http://example.com/p") })
        // The request carried the POST body.
        #expect(client.requests.first?.method == .post)
        #expect(client.requests.first?.body == "payload=1")
        await controller.disconnect()
    }

    @Test("a LuaSocket request table sets method, body, and custom headers")
    func tableBodyWithHeaders() async throws {
        let engine = try ScriptEngine()
        try await engine.loadPlugin(MUSHclientPluginLoader.parse(xml: plugin("""
        function go()
          async.doAsyncRemoteRequest("https://example.com/api", function(r, page, status)
            Send("done:" .. tostring(status))
          end, "HTTPS", 5, nil, {
            method = "POST",
            headers = { ["content-type"] = "application/json", ["authorization"] = "Bearer k" },
            source = '{"a":1}'
          })
        end
        """)))
        let conn = InMemoryConnection()
        let client = StubHTTPClient(HTTPResponse(
            retval: 1, page: "{}", status: 200, headers: "", fullStatus: "HTTP 200", timedOut: false
        ))
        let controller = SessionController(scriptEngine: engine, makeConnection: { conn }, httpClient: client)
        try await controller.connect(to: .init(host: "test.invalid", port: 23))

        try await controller.send("go")

        #expect(await eventually { conn.sentLines.contains("done:200") })
        let req = try #require(client.requests.first)
        #expect(req.method == .post)
        #expect(req.body == #"{"a":1}"#)
        #expect(req.headers["content-type"] == "application/json")
        #expect(req.headers["authorization"] == "Bearer k")
        await controller.disconnect()
    }
}
