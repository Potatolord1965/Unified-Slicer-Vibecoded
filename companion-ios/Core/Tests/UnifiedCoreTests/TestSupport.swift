import Foundation
@testable import UnifiedCore

func json(_ text: String) -> JSON {
    guard let j = JSON.parse(text) else { fatalError("Bad JSON in test: \(text)") }
    return j
}

/// An HTTP client that answers from a handler and records requests.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    let requests = Locked([HTTPRequest]())
    let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    func send(_ request: HTTPRequest, onSent: (@Sendable (Int64) -> Void)?) async throws -> HTTPResponse {
        requests.with { $0.append(request) }
        if case .file(let url)? = request.body { onSent?(fileSize(url)) }
        if case .data(let d)? = request.body { onSent?(Int64(d.count)) }
        return try handler(request)
    }

    static func ok(_ text: String) -> HTTPResponse { HTTPResponse(status: 200, body: Data(text.utf8)) }
}

func noHTTP() -> FakeHTTP { FakeHTTP { _ in throw IOError("No network in tests") } }

func tempFile(_ name: String, _ contents: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uc-tests-\(randomId(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}
