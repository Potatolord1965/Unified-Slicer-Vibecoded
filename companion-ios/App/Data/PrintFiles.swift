import Foundation
import UnifiedCore

/// Files waiting to be sent live in the app's caches; only the newest few are kept.
enum PrintFiles {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("print-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A name printers and URLs cope with: no path, no control or reserved characters.
    static func safeName(_ raw: String?) -> String {
        var name = (raw ?? "").split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        name = name.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        name = String(name.unicodeScalars.map { u -> Character in
            u.value < 0x20 || "\"*:<>?|#%&".unicodeScalars.contains(u) ? "_" : Character(u)
        })
        name = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.isEmpty { name = "print.gcode" }
        return String(name.suffix(120))
    }

    static func newFile(_ name: String) -> URL {
        let fm = FileManager.default
        let d = dir
        let old = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { modified($0) > modified($1) }
        for u in old.dropFirst(4) { try? fm.removeItem(at: u) }
        // One folder per file keeps the original name on disk.
        let folder = d.appendingPathComponent(String(Date().ms), isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(safeName(name))
    }

    private static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Copies a document the user picked or opened in this app into the caches.
    static func importFile(_ url: URL) throws -> PrintJob {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let target = newFile(url.lastPathComponent)
        var copyError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: target) } catch { copyError = error }
        }
        if let e = copyError ?? coordinatorError { throw IOError("Could not read the file: \(e.localizedDescription)") }
        return PrintJob(file: target, name: target.lastPathComponent)
    }

    /// Moves a finished download into the caches.
    static func adopt(_ url: URL, name: String) throws -> PrintJob {
        let target = newFile(name)
        try FileManager.default.moveItem(at: url, to: target)
        return PrintJob(file: target, name: target.lastPathComponent)
    }

    /// Sliced files a printer can run as they are.
    static func isPrinterReady(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".gcode", ".gco", ".g", ".bgcode", ".3mf"].contains { lower.hasSuffix($0) }
    }
}
