import Foundation

private final class ScanHistoryAccess: @unchecked Sendable {
    let lock = NSRecursiveLock()
}

public enum ScanHistoryFailure: LocalizedError {
    case tooLarge
    public var errorDescription: String? { "The report exceeds the local history limit (32 MB)." }
}

struct SavedScan: Codable {
    var report: DiskReport
    var cache: ScanCache?

    init(report: DiskReport, cache: ScanCache?) { self.report = report; self.cache = cache }
    private enum CodingKeys: String, CodingKey { case report, cache }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        report = try container.decode(DiskReport.self, forKey: .report)
        cache = try? container.decodeIfPresent(ScanCache.self, forKey: .cache)
    }
}

/// Report and bounded folder index are replaced together in one atomic write.
public struct ScanHistoryStore: Sendable {
    public let directory: URL
    private let maximumBytes = 32 * 1024 * 1024
    private let access = ScanHistoryAccess()

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.polyakovin.DiskLens", isDirectory: true)) {
        self.directory = directory
    }

    private var file: URL { directory.appendingPathComponent("last-scan.json") }

    public func load() throws -> DiskReport? {
        try loadSnapshot()?.report
    }

    func loadSnapshot() throws -> SavedScan? {
        access.lock.lock(); defer { access.lock.unlock() }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw ScanHistoryFailure.tooLarge
        }
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        // Migrate the earlier report-only format without losing the last result.
        let saved: SavedScan
        if let value = try? decoder.decode(SavedScan.self, from: data) { saved = value }
        else { saved = SavedScan(report: try decoder.decode(DiskReport.self, from: data), cache: nil) }
        return saved.report.schemaVersion == 1 ? saved : nil
    }

    public func save(_ report: DiskReport, cache: ScanCache? = nil, unlessCancelled cancellation: CancellationFlag? = nil) throws {
        access.lock.lock(); defer { access.lock.unlock() }
        guard report.inProgress != true, cancellation?.isCancelled != true else { return }
        // An interrupted/inaccessible scan still contains useful ordering hints.
        // Never replace a complete baseline of the same root with a partial one.
        if report.isPartial, let previous = try? load(), previous.root.path == report.root.path, !previous.isPartial { return }
        var data = try JSONEncoder().encode(SavedScan(report: report, cache: report.cancelled ? nil : cache))
        if data.count > maximumBytes, cache != nil {
            data = try JSONEncoder().encode(SavedScan(report: report, cache: nil))
        }
        guard data.count <= maximumBytes else { throw ScanHistoryFailure.tooLarge }
        guard cancellation?.isCancelled != true else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A filesystem mutation invalidates even a previously complete measurement.
    public func clear() throws {
        access.lock.lock(); defer { access.lock.unlock() }
        do { try FileManager.default.removeItem(at: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
    }
}
