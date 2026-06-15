import Foundation

/// The clean-room `async` HTTP module (split from `LuaRuntime+CompatShim` for the
/// line budget). Mirrors the Aardwolf community's `async.lua`
/// (`doAsyncRemoteRequest`/`HEAD`/`GETFILE`) over `proteles.__http`, so plugins
/// run unmodified. The request body follows LuaSocket's `http.request` form:
/// nil → GET, a string → POST that body, or a table with `method`/`source`/
/// `headers` for full control (e.g. an authenticated JSON POST). Headers are
/// JSON-encoded for the host, which applies them to the URLRequest. The result
/// callback is fired with `(retval, page, status, headers, full_status, url,
/// body)`; a string callback is `loadstring`d, as upstream.
extension LuaRuntime {
    nonisolated static let asyncModuleSource = """
    async = {}
    local function as_func(cb)
      if type(cb) == "string" then return loadstring(cb) end
      return cb
    end
    local function protocol_for(url, p)
      if p and p ~= "" then return p end
      return tostring(url):lower():find("^https:") and "HTTPS" or "HTTP"
    end
    -- request_body (LuaSocket http.request form): nil to GET; a string to POST
    -- that body; a table for full control via its method/source/headers (e.g. an
    -- authenticated JSON POST). Returns (method, body_string, headers_json).
    local function normalize(body)
      if body == nil then return nil, nil, nil end
      if type(body) == "table" then
        local headers = body.headers and proteles.jsonEncode(body.headers) or nil
        return body.method, body.source, headers
      end
      return "POST", tostring(body), nil
    end
    function async.doAsyncRemoteRequest(url, callback, protocol, timeout, on_timeout, body)
      local method, src, headers = normalize(body)
      proteles.__http("request", tostring(url), protocol_for(url, protocol),
        tonumber(timeout) or 30, src, headers, method, as_func(callback), as_func(on_timeout))
    end
    function async.HEAD(url, callback, protocol, timeout, on_timeout)
      proteles.__http("head", tostring(url), protocol_for(url, protocol),
        tonumber(timeout) or 30, nil, nil, nil, as_func(callback), as_func(on_timeout))
    end
    function async.GETFILE(url, callback, protocol, file_name, timeout, on_timeout)
      proteles.__http("getfile", tostring(url), protocol_for(url, protocol),
        tonumber(timeout) or 30, file_name, nil, nil, as_func(callback), as_func(on_timeout))
    end
    return async
    """
}
