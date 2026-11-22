import Foundation

/// The account's sign-in is no longer accepted: the user must sign in again.
public struct AuthError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// An HTTP error with the server's status code and a short body excerpt.
public struct HTTPError: LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public let body: String
    public init(code: Int, message: String, body: String = "") {
        self.code = code
        self.message = message
        self.body = body
    }
    public var errorDescription: String? { message }
}

/// A failure with a message meant for the person using the app.
public struct IOError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A device that failed the certificate check: not the printer it should be.
public struct CertificateError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A reply larger than the request allows.
public struct ResponseTooLarge: Error, Sendable {}

/// A readable message for any error.
public func readable(_ error: Error) -> String {
    if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty { return d }
    return error.localizedDescription
}

public let userAgent = "UnifiedSlicerCompanion/1.0 (iOS)"

public enum HTTPBody: Sendable {
    case data(Data)
    case file(URL)
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: HTTPBody?
    /// Uploads have no overall deadline and generous time-outs.
    public var isUpload: Bool
    /// A larger reply fails with `ResponseTooLarge`.
    public var maxResponseBytes: Int?

    public init(_ url: String, method: String = "GET", headers: [String: String] = [:], body: HTTPBody? = nil, isUpload: Bool = false) throws {
        guard let u = URL(string: url), u.scheme != nil else { throw IOError("Not a valid address: \(url)") }
        self.url = u
        self.method = method
        self.headers = headers
        self.body = body
        self.isUpload = isUpload
        self.maxResponseBytes = nil
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    /// Header names in lower case.
    public let headers: [String: String]
    /// Cookies the server set, by name.
    public let cookies: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], cookies: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.cookies = cookies
        self.body = body
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

/// Sends HTTP requests. The app uses `URLSessionHTTP`; tests use fakes.
public protocol HTTPClient: Sendable {
    /// `onSent` reports the request body bytes sent so far.
    func send(_ request: HTTPRequest, onSent: (@Sendable (Int64) -> Void)?) async throws -> HTTPResponse
}

extension HTTPClient {
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await send(request, onSent: nil)
    }

    private func withAgent(_ request: HTTPRequest) -> HTTPRequest {
        var r = request
        if r.header("User-Agent") == nil { r.headers["User-Agent"] = userAgent }
        return r
    }

    /// The body text; 401/403 become `AuthError`, other non-2xx statuses `HTTPError`.
    public func fetchText(_ request: HTTPRequest, onSent: (@Sendable (Int64) -> Void)? = nil) async throws -> String {
        let r = withAgent(request)
        let resp = try await send(r, onSent: onSent)
        if resp.status == 401 || resp.status == 403 {
            throw AuthError("The printer or service rejected the credentials (HTTP \(resp.status))")
        }
        guard (200..<300).contains(resp.status) else {
            throw HTTPError(code: resp.status, message: "HTTP \(resp.status) from \(r.url.host ?? "the server")", body: String(resp.text.prefix(2000)))
        }
        return resp.text
    }

    /// The parsed JSON body. 401/403 become `AuthError` (unless `authErrors` is false); other
    /// non-2xx statuses become `HTTPError`.
    public func fetchJSON(_ request: HTTPRequest, authErrors: Bool = true) async throws -> JSON {
        let r = withAgent(request)
        let resp = try await send(r)
        if authErrors && (resp.status == 401 || resp.status == 403) {
            throw AuthError("Sign-in rejected (HTTP \(resp.status))")
        }
        guard (200..<300).contains(resp.status) else {
            throw HTTPError(code: resp.status, message: "HTTP \(resp.status) from \(r.url.host ?? "the server")", body: String(resp.text.prefix(2000)))
        }
        let text = resp.text
        guard let json = JSON.parse(text.isEmpty ? "{}" : text) else {
            throw IOError("Unexpected reply from \(r.url.host ?? "the server")")
        }
        return json
    }
}

/// HTTP through URLSession, without cookies or caching.
public final class URLSessionHTTP: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    private let uploads: URLSession

    /// `requestTimeout` is the longest wait for data, `overallTimeout` the longest a request may take.
    public init(requestTimeout: TimeInterval = 20, overallTimeout: TimeInterval = 30) {
        session = URLSession(configuration: Self.configuration(request: requestTimeout, resource: overallTimeout))
        uploads = URLSession(configuration: Self.configuration(request: 180, resource: 7 * 24 * 3600))
    }

    private static func configuration(request: TimeInterval, resource: TimeInterval) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = request
        c.timeoutIntervalForResource = resource
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return c
    }

    public func send(_ request: HTTPRequest, onSent: (@Sendable (Int64) -> Void)?) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let s = request.isUpload ? uploads : session
        let delegate = onSent.map { UploadProgress(onSent: $0) }
        let data: Data
        let response: URLResponse
        do {
            switch request.body {
            case .none:
                if let cap = request.maxResponseBytes {
                    let (bytes, resp) = try await s.bytes(for: r, delegate: delegate)
                    var buffer = Data()
                    for try await b in bytes {
                        buffer.append(b)
                        if buffer.count > cap { throw ResponseTooLarge() }
                    }
                    (data, response) = (buffer, resp)
                } else {
                    (data, response) = try await s.data(for: r, delegate: delegate)
                }
            case .data(let d)?:
                (data, response) = try await s.upload(for: r, from: d, delegate: delegate)
            case .file(let f)?:
                (data, response) = try await s.upload(for: r, fromFile: f, delegate: delegate)
            }
        } catch let e as URLError {
            if e.code == .cancelled || Task.isCancelled { throw CancellationError() }
            throw IOError(Self.describe(e, host: request.url.host))
        }
        guard let http = response as? HTTPURLResponse else { throw IOError("No HTTP reply from \(request.url.host ?? "the server")") }
        var headers: [String: String] = [:]
        var plain: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let name = k as? String, let value = v as? String else { continue }
            headers[name.lowercased()] = value
            plain[name] = value
        }
        var cookies: [String: String] = [:]
        for c in HTTPCookie.cookies(withResponseHeaderFields: plain, for: request.url) { cookies[c.name] = c.value }
        return HTTPResponse(status: http.statusCode, headers: headers, cookies: cookies, body: data)
    }

    static func describe(_ e: URLError, host: String?) -> String {
        let h = host ?? "the server"
        switch e.code {
        case .notConnectedToInternet: return "No internet connection"
        case .timedOut: return "\(h) did not answer in time"
        case .cannotFindHost, .dnsLookupFailed: return "Could not find \(h)"
        case .cannotConnectToHost: return "Could not connect to \(h)"
        case .networkConnectionLost: return "The connection to \(h) was lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "Could not make a secure connection to \(h)"
        default: return "Could not reach \(h): \(e.localizedDescription)"
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onSent: @Sendable (Int64) -> Void
    init(onSent: @escaping @Sendable (Int64) -> Void) { self.onSent = onSent }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(totalBytesSent)
    }
}

// MARK: Addresses

/// URL-encodes like a form (Java's URLEncoder) with spaces as %20.
public func formEncode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
}

private let formAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_")

/// Accepts "192.168.1.5", "192.168.1.5:7125" or "http://host/path" and returns a base URL without a trailing slash.
public func baseUrl(_ host: String, defaultScheme: String = "http") -> String {
    var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
    while h.hasSuffix("/") { h.removeLast() }
    let lower = h.lowercased()
    return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? h : "\(defaultScheme)://\(h)"
}

/// Host part of `host` as entered by the user (no scheme, port or path).
public func bareHost(_ host: String) -> String {
    var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
    if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
    if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
    if h.hasPrefix("[") {
        h.removeFirst()
        if let end = h.firstIndex(of: "]") { h = String(h[..<end]) }
        return h
    }
    if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
    return h
}

/// Size of a file in bytes, 0 when it can't be read.
public func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

extension HTTPRequest {
    /// A request with a JSON body.
    public static func json(_ url: String, method: String = "POST", _ body: JSON, headers: [String: String] = [:]) throws -> HTTPRequest {
        var h = headers
        h["Content-Type"] = "application/json; charset=utf-8"
        return try HTTPRequest(url, method: method, headers: h, body: .data(Data(body.serialized.utf8)))
    }

    /// A request with a form body.
    public static func form(_ url: String, _ fields: [(String, String)], headers: [String: String] = [:]) throws -> HTTPRequest {
        var h = headers
        h["Content-Type"] = "application/x-www-form-urlencoded"
        let text = fields.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        return try HTTPRequest(url, method: "POST", headers: h, body: .data(Data(text.utf8)))
    }

    public func with(_ name: String, _ value: String) -> HTTPRequest {
        var r = self
        r.headers[name] = value
        return r
    }
}

/// Parses an ISO 8601 time, with or without fractional seconds.
public func parseISODate(_ text: String?) -> Date? {
    guard let t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: t) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: t)
}
