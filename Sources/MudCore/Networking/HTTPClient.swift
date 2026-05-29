import Foundation

/// The outcome of an ``HTTPRequest``, shaped for the Aardwolf `async` callback
/// signature `(retval, page, status, headers, full_status, url, body)`.
/// `retval` is 1 when a response was received (even an HTTP error status), 0 on
/// a transport failure — mirroring LuaSocket's return that the reference checks.
public struct HTTPResponse: Sendable, Equatable {
    public let retval: Int
    public let page: String // the body (UTF-8)
    public let status: Int // HTTP status code, 0 if none
    public let headers: String // "Key: Value" lines, newline-joined + sorted
    public let fullStatus: String // a status line / error description
    public let timedOut: Bool

    public init(
        retval: Int,
        page: String,
        status: Int,
        headers: String,
        fullStatus: String,
        timedOut: Bool
    ) {
        self.retval = retval
        self.page = page
        self.status = status
        self.headers = headers
        self.fullStatus = fullStatus
        self.timedOut = timedOut
    }
}

/// Performs a plugin's outbound HTTP request. Injectable so tests drive the
/// `async` path deterministically (``InMemoryHTTPClient``) while the app uses
/// ``URLSessionHTTPClient`` — mirroring the ``MudConnection`` seam.
public protocol HTTPClient: Sendable {
    func perform(_ request: HTTPRequest) async -> HTTPResponse
}

/// `URLSession`-backed HTTP(S) client. HTTPS works natively, so plugin web
/// calls are independent of the deferred telnet-TLS work (D-15). The body is
/// returned to the host; a GETFILE save is done host-side through the plugin
/// sandbox, not here, so this never touches arbitrary paths.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private func failure(_ description: String, timedOut: Bool = false) -> HTTPResponse {
        HTTPResponse(retval: 0, page: "", status: 0, headers: "", fullStatus: description, timedOut: timedOut)
    }

    public func perform(_ request: HTTPRequest) async -> HTTPResponse {
        guard let url = URL(string: request.url) else { return failure("invalid URL") }
        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout > 0 ? request.timeout : 30)
        urlRequest.httpMethod = request.method.rawValue
        if request.method == .post, let body = request.body {
            urlRequest.httpBody = Data(body.utf8)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let headers = ((response as? HTTPURLResponse)?.allHeaderFields ?? [:])
                .map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
            return HTTPResponse(
                retval: 1,
                page: String(decoding: data, as: UTF8.self),
                status: status,
                headers: headers,
                fullStatus: "HTTP \(status)",
                timedOut: false
            )
        } catch let error as URLError where error.code == .timedOut {
            return failure("timed out", timedOut: true)
        } catch {
            return failure(error.localizedDescription)
        }
    }
}
