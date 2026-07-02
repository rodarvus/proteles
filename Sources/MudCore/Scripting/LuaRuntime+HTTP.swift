import CLua
import Foundation

/// The runtime side of the `async` HTTP helper: record a plugin's request
/// (holding its Lua callback across the network round-trip) and, once the host
/// has performed it, fire that callback with the response.
///
/// The callback arrives as a transient function ref (freed at chunk end); we
/// ``LuaRuntime/claim(_:)`` it so it survives until completion, then release it.
/// The host (`SessionController`) performs the request off-actor via an
/// ``HTTPClient`` and re-enters ``completeHTTPRequest(_:_:)`` on the actor.
extension LuaRuntime {
    struct PendingHTTPRequest {
        let callback: Int32?
        let onTimeout: Int32?
        let variableScope: String
        let pluginContext: PluginContext
    }

    /// `proteles.__http(kind, url, protocol, timeout, payload, callback,
    /// onTimeout)` — record an outbound request as a `.httpRequest` effect,
    /// stashing the (claimed) callback refs under a fresh id. `kind` is
    /// `request` (GET, or POST when `payload` is a body), `head`, or `getfile`
    /// (GET whose body is saved to the `payload` path, sandbox-guarded).
    nonisolated func registerHTTPRequest(_ arguments: [LuaValue]) {
        // Arg order (set by the `async` shim): kind, url, protocol(unused here),
        // timeout, body, headersJSON, method, callback, onTimeout.
        let kind = Self.argString(arguments, 0)
        let url = Self.argString(arguments, 1)
        guard !url.isEmpty else { return }
        let timeout = Self.argDouble(arguments, 3)
        let payload = Self.argOptionalString(arguments, 4)
        let headers = Self.decodeHeaders(Self.argOptionalString(arguments, 5))
        let methodHint = Self.argOptionalString(arguments, 6)
        let callback = Self.argFunctionRef(arguments, 7)
        let onTimeout = Self.argFunctionRef(arguments, 8)

        let method: HTTPRequest.Method
        var body: String?
        var savePath: String?
        switch kind {
        case "head":
            method = .head
        case "getfile":
            method = .get
            savePath = payload // the GETFILE target path travels in the body slot
        default: // "request"
            // The shim sends the table's `method` (POST/GET/…); fall back to POST
            // when there's a body, else GET — matching LuaSocket's `http.request`.
            body = payload
            method = methodHint.flatMap { HTTPRequest.Method(rawValue: $0.uppercased()) }
                ?? (payload?.isEmpty == false ? .post : .get)
        }

        let id = nextHTTPRequestID
        nextHTTPRequestID += 1
        pendingHTTP[id] = PendingHTTPRequest(
            callback: callback.map { claim($0) },
            onTimeout: onTimeout.map { claim($0) },
            variableScope: currentVariableScope,
            pluginContext: pluginContext
        )
        effects.append(.httpRequest(HTTPRequest(
            id: id,
            url: url,
            method: method,
            body: body,
            headers: headers,
            savePath: savePath,
            timeout: timeout
        )))
    }

    /// Decode a JSON object of request headers (`{"Content-Type":"…"}`) the
    /// `async` shim builds via `proteles.jsonEncode`, into `[field: value]`.
    /// Non-string values are stringified; nil/invalid input is no headers.
    private nonisolated static func decodeHeaders(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
    }

    /// Fire the stored callback for `request` with `response` and return the
    /// effects it produced. A timeout routes to the timeout callback (or a red
    /// note if none); otherwise the result callback gets `(retval, page, status,
    /// headers, full_status, url, body)`. A GETFILE writes the body to its path
    /// through the plugin sandbox first, then passes the path as `page`. Refs
    /// are released afterwards. A no-op if the id is unknown (already fired).
    func completeHTTPRequest(_ request: HTTPRequest, _ response: HTTPResponse) -> [ScriptEffect] {
        guard let pending = pendingHTTP.removeValue(forKey: request.id) else { return [] }
        effects.removeAll(keepingCapacity: true)
        let previousScope = currentVariableScope
        let previousContext = pluginContext
        currentVariableScope = pending.variableScope
        pluginContext = pluginContexts[pending.pluginContext.pluginID] ?? pending.pluginContext
        defer {
            currentVariableScope = previousScope
            pluginContext = previousContext
            if let callback = pending.callback { luaL_unref(state, LUA_REGISTRYINDEX, callback) }
            if let onTimeout = pending.onTimeout { luaL_unref(state, LUA_REGISTRYINDEX, onTimeout) }
            releaseTransientRefs()
        }
        let bodyValue: LuaValue = request.body.map(LuaValue.string) ?? .nil

        if response.timedOut {
            if let onTimeout = pending.onTimeout {
                invokeHandlers(
                    [onTimeout],
                    payload: [.string(request.url), .number(request.timeout), bodyValue]
                )
            } else {
                effects.append(.note(
                    text: "Async request to \(request.url) timed out.",
                    foreground: "red",
                    background: nil
                ))
            }
            return effects
        }

        var page = response.page
        if let savePath = request.savePath, response.retval == 1 {
            _ = writeFileAllowed(savePath, page) // sandbox-guarded; ignores out-of-sandbox paths
            page = savePath
        }
        if let callback = pending.callback {
            invokeHandlers([callback], payload: [
                .number(Double(response.retval)),
                .string(page),
                .number(Double(response.status)),
                .string(response.headers),
                .string(response.fullStatus),
                .string(request.url),
                bodyValue
            ])
        }
        return effects
    }
}
