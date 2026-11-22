import Foundation

/// Base for LAN printers polled over HTTP with an optional X-Api-Key. Unreachable means offline.
public class HTTPPrinterSource: PrinterSource, @unchecked Sendable {
    public let printer: LanPrinter
    let ctx: SourceContext
    let base: String

    var via: String { "LAN" }

    init(_ printer: LanPrinter, _ ctx: SourceContext) {
        self.printer = printer
        self.ctx = ctx
        base = baseUrl(printer.host)
    }

    public var account: Account { .lan(printer) }

    var keyHeaders: [String: String] {
        let key = printer.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? [:] : ["X-Api-Key": key]
    }

    func get(_ path: String) async throws -> JSON {
        try await ctx.http.fetchJSON(try HTTPRequest(base + path, headers: keyHeaders))
    }

    /// A request to `path` carrying the API key.
    func request(_ path: String, method: String = "GET", headers: [String: String] = [:], body: HTTPBody? = nil, isUpload: Bool = false) throws -> HTTPRequest {
        try HTTPRequest(base + path, method: method, headers: keyHeaders.merging(headers) { _, new in new }, body: body, isUpload: isUpload)
    }

    /// POSTs `json` (or `{}`) to `path`; throws on an HTTP error.
    func post(_ path: String, _ json: String? = nil) async throws {
        do {
            _ = try await ctx.http.fetchText(try request(
                path, method: "POST", headers: ["Content-Type": "application/json; charset=utf-8"], body: .data(Data((json ?? "{}").utf8))
            ))
        } catch let e as HTTPError where e.code == 409 {
            throw IOError("The printer cannot do that right now")
        }
    }

    /// Uploads `job` as a multipart form with `fields`, reporting progress 0...100.
    func uploadMultipart(_ path: String, fields: [(String, String)], job: PrintJob, progress: @escaping SendProgress) async throws {
        let form = Multipart()
        let body = try form.write(fields: fields, fileField: "file", fileName: job.name, file: job.file)
        defer { try? FileManager.default.removeItem(at: body) }
        let size = max(fileSize(body), 1)
        _ = try await ctx.http.fetchText(
            try request(path, method: "POST", headers: ["Content-Type": form.contentType], body: .file(body), isUpload: true),
            onSent: { sent in progress(Int(min(sent * 100 / size, 100)), nil) }
        )
    }

    /// `url` as an absolute address; relative ones are on the printer.
    func resolve(_ url: String) -> String {
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        return url.hasPrefix("/") ? b + url : b + "/" + url
    }

    /// URL-encodes each segment of `path`, keeping the slashes.
    func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { formEncode(String($0)) }.joined(separator: "/")
    }

    func status(_ state: PrinterState) -> PrinterStatus {
        PrinterStatus(accountId: printer.id, deviceId: printer.host, name: printer.label, model: printer.kind.label, brand: printer.kind.brand, via: via, state: state)
    }

    func read() async throws -> PrinterStatus { status(.unknown) }

    public func refresh() async throws -> [PrinterStatus] {
        do {
            return [try await read()]
        } catch let e as AuthError {
            throw e
        } catch let e as HTTPError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return [status(.offline)]
        }
    }

    public func close() {}
}

/// The temperature in `json[group]`, e.g. {"temperature": 210, "target": 215}.
func groupTemp(_ json: JSON?, _ group: String, cur: String = "temperature", target: String = "target") -> Temperature? {
    guard let g = json.obj(group), let c = g.num(cur) else { return nil }
    return Temperature(c, target: g.num(target).flatMap { $0 > 0 ? $0 : nil })
}

/// A multipart/form-data body written to a temporary file, so large files stream from disk.
struct Multipart {
    let boundary = "usc-" + randomId(24)
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    static func quoted(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\r", with: "%0D")
    }

    func write(fields: [(String, String)], fileField: String, fileName: String, file: URL) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(randomId(10)).form")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let h = try FileHandle(forWritingTo: out)
        defer { try? h.close() }
        var head = ""
        for (k, v) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(k))\"\r\n\r\n\(v)\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(fileField))\"; filename=\"\(Self.quoted(fileName))\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        h.write(Data(head.utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            h.write(chunk)
        }
        h.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }
}
